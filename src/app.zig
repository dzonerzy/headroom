//! What the page calls: scan a folder, look at one of its folders (the
//! treemap laid out for the map's size, drawn by the layer; labels and the
//! legend for the page), what is under the mouse.

const std = @import("std");
const plume = @import("plume");
const scanner = @import("scan.zig");
const treemap = @import("treemap.zig");
const categories = @import("categories.zig");
const volume = @import("volume.zig");
const map_layer = @import("map.zig");
const elevate = @import("elevate.zig");
const removing = @import("remove.zig");

pub const App = struct {
    pub const async_methods = .{ "scan", "remove" };
    /// main.zig's, not the page's.
    pub const hidden = .{ "startWatching", "menuChosen", "closing" };

    pub const Events = struct {
        progress: Progress,
        /// The tray asks the page to scan a folder.
        request_scan: []const u8,
        /// Watching free space was turned on or off (from the tray).
        watching: bool,
    };

    pub const Progress = struct { files: u64, folders: u64, bytes: u64, unreadable: u64 };

    pub const Scanned = struct {
        path: []const u8,
        size: u64,
        files: u64,
        entries: u64,
        unreadable: u64,
        ms: u64,
    };

    pub const Crumb = struct { node: u32, name: []const u8 };

    pub const Legend = struct {
        name: []const u8,
        /// "#5b8def": the color the map draws it with.
        color: []const u8,
        size: u64,
    };

    pub const View = struct {
        node: u32,
        path: []const u8,
        /// From the scanned folder down to this one.
        crumbs: []const Crumb,
        size: u64,
        files: u64,
        labels: []const treemap.Label,
        legend: []const Legend,
        /// The map zooms to it: labels wait for the zoom's end.
        zoom_ms: u32,
    };

    pub const Kind = enum { folder, file, link, mount, other, rest };

    pub const Item = struct {
        node: u32,
        kind: Kind,
        /// The rest's folder's name for `rest`.
        name: []const u8,
        path: []const u8,
        size: u64,
        files: u64,
        /// For `rest`: how many items it gathers.
        count: u32,
        category: ?Legend,
        /// Of the folder being looked at.
        share: f64,
        unreadable: bool,
        /// A folder that can be opened (click).
        opens: bool,
    };

    /// What deleting an item means, asked before it is deleted.
    pub const Removal = struct {
        node: u32,
        name: []const u8,
        path: []const u8,
        size: u64,
        files: u64,
        folder: bool,
        /// Why it cannot be deleted; null if it can.
        refused: ?[]const u8,
        /// What deleting it breaks that is easy to miss.
        warning: ?[]const u8,
        /// The generation of the scan it is from: remove() refuses an item
        /// of an older scan.
        generation: u32,
    };

    pub const Removed = struct { size: u64, files: u64 };

    io: std.Io,
    home_path: []const u8,
    map: *map_layer.Map,
    /// `--scan <path>` (a restart as administrator): scanned at the start.
    startup_scan: ?[]const u8 = null,
    /// The scanned disk's used bytes: how much of it a scan has lit.
    scan_used: u64 = 0,
    /// Set by main.zig: how the scan's thread sends progress.
    events: ?plume.Events(Events) = null,

    lock: std.Io.Mutex = .init,
    tree: ?scanner.Tree = null,
    layout: ?treemap.Layout = null,
    root: u32 = 0,
    legend_root: ?u32 = null,
    legend_sizes: [categories.count]u64 = @splat(0),
    cancel: std.atomic.Value(bool) = .init(false),
    scanning: std.atomic.Value(bool) = .init(false),
    /// Counts scans: what a removal was asked about must still be there.
    generation: u32 = 0,

    /// Set by main.zig: the tray, notifications and the window are its.
    plume_app: ?*plume.App = null,
    /// Where "watch free space" is remembered (null: not remembered).
    settings_path: ?[]const u8 = null,
    /// Watching free space: the tray icon, there while it is on.
    tray: ?*plume.Tray = null,
    /// Told already that the disk is nearly full (until it has room again).
    alarmed: bool = false,

    /// Below this share of the disk free, the alarm: the meter's red zone.
    pub const alarm_below = 0.10;

    const gpa = std.heap.smp_allocator;

    /// The app is ending: a scan still running stops now (app.deinit waits
    /// for it, and a whole disk takes minutes).
    pub fn stop(self: *App) void {
        self.cancelScan();
    }

    pub fn deinit(self: *App) void {
        if (self.layout) |*l| l.deinit(gpa);
        if (self.tree) |*t| t.deinit(gpa);
    }

    /// Where a scan starts by default: the user's home folder.
    pub fn home(self: *App) []const u8 {
        return self.home_path;
    }

    /// The disk holding `path`: its size and what is free.
    pub fn space(self: *App, path: []const u8) ?volume.Space {
        _ = self;
        return volume.space(gpa, path);
    }

    /// The folder to scan at once (Headroom restarted as administrator to
    /// scan it), the first time it is asked.
    pub fn startupScan(self: *App) ?[]const u8 {
        defer self.startup_scan = null;
        return self.startup_scan;
    }

    /// Whether Headroom runs as administrator (root on Linux).
    pub fn admin(self: *App) bool {
        _ = self;
        return elevate.isAdmin();
    }

    /// Headroom again as administrator (Windows' prompt), scanning `path`
    /// once it starts; then the page quits this one.
    pub fn restartAsAdmin(self: *App, path: []const u8) elevate.Error!void {
        return elevate.restart(gpa, self.io, path);
    }

    /// The intro on the map (no treemap yet: the start, a scan running, a
    /// failed one), in the map's area as for view().
    pub fn intro(self: *App, x: f32, y: f32, width: f32, height: f32, scale: f32) void {
        self.map.showIntro(.{ .x = x, .y = y, .w = width, .h = height }, scale);
        if (!self.scanning.load(.acquire)) self.map.setActivity(idle_detail, 1, 0);
    }

    const idle_detail = 9;

    /// Everything under `path`, on a worker thread: "progress" events while
    /// it runs (the intro deepens as files come). Then view(0, ...) shows it.
    pub fn scan(self: *App, allocator: std.mem.Allocator, path: []const u8) (scanner.Error || error{Busy})!Scanned {
        if (self.scanning.swap(true, .acq_rel)) return error.Busy;
        defer self.scanning.store(false, .release);
        self.cancel.store(false, .monotonic);
        self.scan_used = if (volume.space(gpa, path)) |s| s.total - s.free else 0;
        self.map.setActivity(4, 2.6, 0);
        defer self.map.setActivity(idle_detail, 1, 0);

        const start = std.Io.Clock.awake.now(self.io);
        var tree = try scanner.scan(gpa, self.io, path, .{
            .report = .{ .context = self, .call = report },
            .cancel = &self.cancel,
        });
        const ms = start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
        const top = tree.node(scanner.Tree.root_index);
        const result: Scanned = .{
            .path = try allocator.dupe(u8, tree.root),
            .size = top.size,
            .files = top.files,
            .entries = tree.nodes.items.len,
            .unreadable = tree.unreadable,
            .ms = @intCast(@max(ms, 0)),
        };

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.layout) |*l| l.deinit(gpa);
        self.layout = null;
        if (self.tree) |*t| t.deinit(gpa);
        self.tree = tree;
        self.generation +%= 1;
        self.root = scanner.Tree.root_index;
        self.legend_root = null;
        self.map.clear();
        return result;
    }

    fn report(context: *anyopaque, progress: scanner.Progress) void {
        const self: *App = @ptrCast(@alignCast(context));
        // A level deeper for every tenfold of files: 1,000 files 7, a million 10.
        // Lit: the share of the disk's used space found so far.
        const files: f32 = @floatFromInt(progress.files + 1);
        const lit: f32 = if (self.scan_used == 0) 0 else @floatCast(@min(@as(f64, @floatFromInt(progress.bytes)) / @as(f64, @floatFromInt(self.scan_used)), 1));
        self.map.setActivity(std.math.clamp(4 + std.math.log10(files), 4, 11), 2.6, lit);
        if (self.events) |events| events.emit(.progress, .{
            .files = progress.files,
            .folders = progress.directories,
            .bytes = progress.bytes,
            .unreadable = progress.unreadable,
        });
    }

    /// Stops a scan running: it fails with Canceled.
    pub fn cancelScan(self: *App) void {
        self.cancel.store(true, .monotonic);
    }

    /// The folder `node` on the map: laid out for the map's area (CSS pixels
    /// in the window, `scale` device pixels each), drawn by the layer,
    /// zooming when it is inside or above the one shown before.
    pub fn view(self: *App, allocator: std.mem.Allocator, node: u32, x: f32, y: f32, width: f32, height: f32, scale: f32) error{ NoScan, NotAFolder, OutOfMemory }!View {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return error.NoScan);
        if (node >= tree.nodes.items.len or tree.node(node).kind != .directory) return error.NotAFolder;

        const bounds: treemap.Rect = .{ .x = 0, .y = 0, .w = @max(width, 1), .h = @max(height, 1) };
        var next = try treemap.layout(gpa, tree, node, bounds, .{});
        errdefer next.deinit(gpa);

        var zoom: ?[4]f32 = null;
        if (self.layout) |*old| {
            if (node != self.root and isAbove(tree, self.root, node)) {
                // In: from where it (or the nearest folder holding it) was.
                var at = node;
                while (at != self.root) : (at = tree.node(at).parent) {
                    if (old.find(at)) |rect| {
                        zoom = map_layer.zoomIn(rect, bounds);
                        break;
                    }
                }
            } else if (node != self.root and isAbove(tree, node, self.root)) {
                // Out: from the folder left, filling the map.
                var at = self.root;
                while (at != node) : (at = tree.node(at).parent) {
                    if (next.find(at)) |rect| {
                        zoom = map_layer.zoomOut(rect, bounds);
                        break;
                    }
                }
            }
            old.deinit(gpa);
        }
        self.layout = next;
        self.root = node;
        self.map.setViewport(.{ .x = x, .y = y, .w = width, .h = height }, scale);
        try self.map.show(gpa, &self.layout.?, zoom);

        var crumbs: std.ArrayList(Crumb) = .empty;
        var at = node;
        while (true) : (at = tree.node(at).parent) {
            try crumbs.append(allocator, .{ .node = at, .name = try allocator.dupe(u8, if (at == 0) tree.root else tree.name(at)) });
            if (at == 0) break;
        }
        std.mem.reverse(Crumb, crumbs.items);

        const labels = try allocator.dupe(treemap.Label, self.layout.?.labels.items);
        for (labels) |*l| l.name = try allocator.dupe(u8, l.name);

        return .{
            .node = node,
            .path = try tree.path(allocator, node),
            .crumbs = crumbs.items,
            .size = tree.node(node).size,
            .files = tree.node(node).files,
            .labels = labels,
            .legend = try self.legend(allocator, tree, node),
            .zoom_ms = if (zoom != null) @intFromFloat(map_layer.Map.zoom_ms) else 0,
        };
    }

    /// What is at (x, y) on the map (CSS pixels from its corner), lit on the
    /// map; null (and nothing lit) off the map or for x < 0.
    pub fn hover(self: *App, allocator: std.mem.Allocator, x: f32, y: f32) error{OutOfMemory}!?Item {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return null);
        const layout = &(self.layout orelse return null);
        const index = if (x < 0) null else layout.hit(x, y);
        self.map.hover(index);
        const item = layout.items.items[index orelse return null];
        const n = tree.node(item.node);
        const view_size: f64 = @floatFromInt(@max(tree.node(self.root).size, 1));
        const size = if (item.shape == .rest) item.size else n.size;
        const category = if (item.shape == .file) categories.info.get(item.category) else null;
        return .{
            .node = item.node,
            .kind = if (item.shape == .rest) .rest else switch (n.kind) {
                .directory => .folder,
                .file => .file,
                .link => .link,
                .mount => .mount,
                .other => .other,
            },
            .name = try allocator.dupe(u8, if (item.node == 0) tree.root else tree.name(item.node)),
            .path = try tree.path(allocator, item.node),
            .size = size,
            .files = if (item.shape == .rest) 0 else n.files,
            .count = item.count,
            .category = if (category) |c| .{ .name = c.name, .color = try hex(allocator, c.color), .size = size } else null,
            .share = @as(f64, @floatFromInt(size)) / view_size,
            .unreadable = n.unreadable,
            .opens = item.shape != .rest and n.kind == .directory and n.child_count > 0 and item.node != self.root,
        };
    }

    /// What deleting `node` means: refused (and why), warned about, or fine.
    pub fn removal(self: *App, allocator: std.mem.Allocator, node: u32) error{ NoScan, NotFound, OutOfMemory }!Removal {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return error.NoScan);
        if (node >= tree.nodes.items.len) return error.NotFound;
        const n = tree.node(node);
        const path = try tree.path(allocator, node);
        return .{
            .node = node,
            .name = try allocator.dupe(u8, if (node == 0) tree.root else tree.name(node)),
            .path = path,
            .size = n.size,
            .files = n.files,
            .folder = n.kind == .directory,
            .refused = removing.refusal(path, self.home_path, tree.root),
            .warning = removing.warning(path),
            .generation = self.generation,
        };
    }

    /// Deletes `node` (to the Recycle Bin or the Trash, or for good), on a
    /// worker thread, then takes it out of the tree: the folders above it
    /// shrink, nothing is scanned again. view() shows the change.
    pub fn remove(self: *App, node: u32, generation: u32, mode: removing.Mode) (removing.Error || error{ NoScan, Refused, Stale })!Removed {
        const path = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const tree = &(self.tree orelse return error.NoScan);
            if (generation != self.generation or node >= tree.nodes.items.len) return error.Stale;
            const path = try tree.path(gpa, node);
            if (removing.refusal(path, self.home_path, tree.root) != null) {
                gpa.free(path);
                return error.Refused;
            }
            break :blk path;
        };
        defer gpa.free(path);

        try removing.remove(gpa, self.io, path, mode, self.home_path);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return error.NoScan);
        if (generation != self.generation) return .{ .size = 0, .files = 0 };
        const n = &tree.nodes.items[node];
        const removed: Removed = .{ .size = n.size, .files = n.files };
        n.size = 0;
        n.files = 0;
        n.child_count = 0;
        var at = n.parent;
        while (true) : (at = tree.nodes.items[at].parent) {
            const parent = &tree.nodes.items[at];
            parent.size -|= removed.size;
            parent.files -|= removed.files;
            if (at == 0) break;
        }
        self.legend_root = null;
        return removed;
    }

    // ---- Watching free space: the tray and the alarm ----

    /// Whether Headroom watches free space from the tray.
    pub fn watching(self: *App) bool {
        return self.tray != null;
    }

    /// Watching free space on or off (remembered): the tray icon comes or
    /// goes; while on, closing the window keeps Headroom in the tray.
    pub fn setWatching(self: *App, on: bool) error{Unsupported}!void {
        if (on == (self.tray != null)) return;
        if (on) self.startWatching() catch return error.Unsupported else self.stopWatching();
        self.saveSettings();
    }

    /// The disk's headroom on the tray, and the alarm once it is nearly
    /// full. The page calls it every minute, the tray once a minute too.
    pub fn watchTick(self: *App) void {
        const tray = self.tray orelse return;
        const app = self.plume_app orelse return;
        const s = volume.space(gpa, self.home_path) orelse return;
        if (s.total == 0) return;
        const free_share = @as(f64, @floatFromInt(s.free)) / @as(f64, @floatFromInt(s.total));
        var free_text: [32]u8 = undefined;
        var level: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&level, "{s} free on {s} ({d:.0}%)", .{ human(&free_text, s.free), driveOf(self.home_path), free_share * 100 }) catch return;
        var tip: [128]u8 = undefined;
        tray.setTooltip(std.fmt.bufPrint(&tip, "Headroom: {s}", .{label}) catch label) catch {};
        tray.setMenu(&trayMenu(label, app.startsAtLogin())) catch {};

        if (free_share < alarm_below and !self.alarmed) {
            self.alarmed = true;
            var body: [192]u8 = undefined;
            app.notify(.{
                .title = "Your disk is almost full",
                .body = std.fmt.bufPrint(&body, "{s} has {s} of headroom left ({d:.0}%). Open Headroom to see what fills it.", .{ driveOf(self.home_path), human(&free_text, s.free), free_share * 100 }) catch null,
                .tag = "headroom-low",
            }) catch {};
        } else if (free_share > alarm_below + 0.01) {
            self.alarmed = false;
        }
    }

    /// main.zig: the tray, when watching was on last time.
    pub fn startWatching(self: *App) !void {
        const app = self.plume_app orelse return error.Unsupported;
        self.tray = try app.createTray(.{ .tooltip = "Headroom", .menu = &trayMenu("Headroom", app.startsAtLogin()) });
        self.watchTick();
    }

    fn stopWatching(self: *App) void {
        const app = self.plume_app orelse return;
        if (self.tray) |tray| app.destroyTray(tray);
        self.tray = null;
        self.alarmed = false;
    }

    /// main.zig: an item of the tray's menu.
    pub fn menuChosen(self: *App, id: []const u8) void {
        const app = self.plume_app orelse return;
        const eql = std.mem.eql;
        if (eql(u8, id, "open")) {
            app.window().show() catch {};
            app.window().focus() catch {};
        } else if (eql(u8, id, "scan-home") or eql(u8, id, "scan-disk")) {
            app.window().show() catch {};
            app.window().focus() catch {};
            const path = if (eql(u8, id, "scan-home")) self.home_path else driveOf(self.home_path);
            if (self.events) |events| events.emit(.request_scan, path);
        } else if (eql(u8, id, "login")) {
            app.setStartAtLogin(!app.startsAtLogin()) catch {};
            self.watchTick();
        } else if (eql(u8, id, "stop")) {
            self.stopWatching();
            self.saveSettings();
            if (self.events) |events| events.emit(.watching, false);
        } else if (eql(u8, id, "quit")) {
            app.quit();
        }
    }

    /// main.zig: the window asked to close. While watching it hides
    /// instead: Headroom stays in the tray.
    pub fn closing(self: *App) bool {
        const app = self.plume_app orelse return true;
        if (self.tray == null) return true;
        app.window().hide() catch return true;
        return false;
    }

    fn saveSettings(self: *App) void {
        const path = self.settings_path orelse return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |folder| cwd.createDirPath(self.io, folder) catch return;
        const text = if (self.tray != null) "{\"watch\":true}\n" else "{\"watch\":false}\n";
        cwd.writeFile(self.io, .{ .sub_path = path, .data = text }) catch {};
    }

    /// main.zig: whether watching was on last time.
    pub fn savedWatching(io: std.Io, path: []const u8) bool {
        var buffer: [256]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return false;
        return std.mem.indexOf(u8, text, "\"watch\":true") != null;
    }

    /// The categories under `node`, biggest first (cached for the last one).
    fn legend(self: *App, allocator: std.mem.Allocator, tree: *const scanner.Tree, node: u32) ![]const Legend {
        if (self.legend_root != node) {
            self.legend_sizes = @splat(0);
            var stack: std.ArrayList(u32) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, node);
            while (stack.pop()) |at| {
                const n = tree.node(at);
                for (tree.children(at), 0..) |child, i| {
                    const index = n.first_child + @as(u32, @intCast(i));
                    switch (child.kind) {
                        .directory => try stack.append(gpa, index),
                        .file => self.legend_sizes[@intFromEnum(categories.of(tree.name(index)))] += child.size,
                        else => {},
                    }
                }
            }
            self.legend_root = node;
        }
        var out: std.ArrayList(Legend) = .empty;
        for (self.legend_sizes, 0..) |size, i| {
            if (size == 0) continue;
            const c = categories.info.get(@enumFromInt(i));
            try out.append(allocator, .{ .name = c.name, .color = try hex(allocator, c.color), .size = size });
        }
        std.mem.sort(Legend, out.items, {}, struct {
            fn bigger(_: void, l: Legend, r: Legend) bool {
                return l.size > r.size;
            }
        }.bigger);
        return out.items;
    }
};

/// The tray's menu: the headroom (a line to read, not choose), then what
/// can be done from there.
fn trayMenu(level: []const u8, login: bool) [9]plume.menu.Item {
    const menu = plume.menu;
    return .{
        .{ .action = .{ .id = "level", .label = level, .enabled = false } },
        menu.separator,
        menu.item("open", "Open Headroom", null),
        menu.item("scan-home", "Scan your home folder", null),
        menu.item("scan-disk", "Scan the whole disk", null),
        menu.separator,
        menu.checkbox("login", "Start at login", login),
        menu.item("stop", "Stop watching free space", null),
        menu.item("quit", "Quit Headroom", null),
    };
}

/// "C:\" for "C:\Users\ada", "/" on Linux.
fn driveOf(path: []const u8) []const u8 {
    if (path.len >= 3 and path[1] == ':') return path[0..3];
    return "/";
}

/// Bytes for people, as the page writes them: "284 GB", "9.5 GB".
fn human(buffer: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB", "PB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024 and unit < units.len - 1) : (unit += 1) value /= 1024;
    if (unit == 0) return std.fmt.bufPrint(buffer, "{d} bytes", .{n}) catch "";
    if (value < 100) return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "";
    return std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ value, units[unit] }) catch "";
}

/// Whether `above` is `node` or holds it.
fn isAbove(tree: *const scanner.Tree, above: u32, node: u32) bool {
    var at = node;
    while (true) : (at = tree.node(at).parent) {
        if (at == above) return true;
        if (at == 0) return false;
    }
}

fn hex(allocator: std.mem.Allocator, color: u24) ![]const u8 {
    return std.fmt.allocPrint(allocator, "#{x:0>6}", .{color});
}

test "the tray's words" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 bytes", human(&buffer, 12));
    try std.testing.expectEqualStrings("9.5 GB", human(&buffer, 9.5 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("284 GB", human(&buffer, 284 * 1024 * 1024 * 1024));
    try std.testing.expectEqualStrings("C:\\", driveOf("C:\\Users\\ada"));
    try std.testing.expectEqualStrings("/", driveOf("/home/ada"));
}
