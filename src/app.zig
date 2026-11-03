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
const rules = @import("rules.zig");
const projects = @import("projects.zig");
const wsl = @import("wsl.zig");
const docker = @import("docker.zig");
const dupes = @import("dupes.zig");
const snapshot = @import("snapshot.zig");
const disk_list = @import("disks.zig");

pub const App = struct {
    pub const async_methods = .{ "scan", "scanDistro", "remove", "removeMany", "emptyBin", "compactDistro", "dockerUsage", "dockerPrune", "findDuplicates" };
    /// main.zig's, not the page's.
    pub const hidden = .{ "startWatching", "menuChosen", "closing" };

    pub const Events = struct {
        progress: Progress,
        /// The tray asks the page to scan a folder.
        request_scan: []const u8,
        /// Watching free space was turned on or off (from the tray).
        watching: bool,
        /// The duplicate search's progress.
        duplicates: dupes.DupesProgress,
    };

    /// Files with the same bytes, a megabyte and up, in the last scan.
    pub const Dupes = struct {
        groups: []const DupeGroup,
        /// What removing all copies but one would give back.
        wasted: u64,
        generation: u32,
    };

    pub const DupeGroup = struct {
        size: u64,
        wasted: u64,
        copies: []const DupeCopy,
    };

    pub const DupeCopy = struct {
        node: u32,
        name: []const u8,
        /// From the folder scanned.
        path: []const u8,
        parent: u32,
        /// Seconds since 1970.
        mtime: i64,
    };

    pub const Progress = struct { files: u64, folders: u64, bytes: u64, unreadable: u64 };

    pub const Scanned = struct {
        path: []const u8,
        size: u64,
        files: u64,
        entries: u64,
        unreadable: u64,
        ms: u64,
        /// Read from the disk's file table (Windows, as administrator):
        /// exact, hard links once.
        from_mft: bool,
        /// Inside a WSL distribution: what goes is deleted for good (the
        /// Recycle Bin does not take its files).
        wsl: bool,
    };

    pub const Distro = wsl.Distro;
    pub const DockerUsage = docker.Usage;
    pub const DockerPrune = docker.Prune;

    pub const Compacted = struct { before: u64, after: u64 };

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

    /// What changed since the folder's last scan.
    pub const Changed = struct {
        since_ms: i64,
        before: u64,
        after: u64,
        grew: []const Moved,
        shrank: []const Moved,
    };

    pub const Moved = struct {
        /// From the folder scanned.
        path: []const u8,
        before: u64,
        after: u64,
        /// Where it is in the tree now (null: it is gone).
        node: ?u32,
        /// Where the map goes for it.
        parent: ?u32,
    };

    /// What a group's cleaning did.
    pub const Cleaned = struct {
        size: u64,
        count: u32,
        /// Items that could not go, and why the first one could not.
        failed: u32,
        reason: ?[]const u8,
    };

    /// What can go, found by the rules in the last scan.
    pub const Reclaim = struct {
        /// What goes by itself or comes back with a build: the headline.
        size: u64,
        /// What needs a look first (virtual disks, the Recycle Bin, ...).
        careful: u64,
        groups: []const Group,
        generation: u32,
    };

    pub const Group = struct {
        id: []const u8,
        title: []const u8,
        why: []const u8,
        risk: rules.Risk,
        action: rules.Action,
        command: ?[]const u8,
        size: u64,
        count: u32,
        /// The biggest ones (at most 40).
        items: []const Place,
        /// All of them: what removeMany deletes.
        nodes: []const u32,
    };

    pub const Place = struct {
        node: u32,
        /// From the folder scanned ("projects/web/node_modules").
        path: []const u8,
        size: u64,
        /// The folder it is in: where the map goes for it.
        parent: u32,
    };

    /// Projects untouched for a while that still hold what their tools
    /// make again.
    pub const Stale = struct {
        projects: []const StaleProject,
        /// What can go in all of them.
        size: u64,
        /// Untouched since (seconds since 1970).
        cutoff: i64,
        generation: u32,
    };

    pub const StaleProject = struct {
        node: u32,
        name: []const u8,
        /// From the folder scanned.
        path: []const u8,
        parent: u32,
        /// Seconds since 1970.
        last_touched: i64,
        size: u64,
        /// Its folders that can go, largest first.
        items: []const Place,
        nodes: []const u32,
    };

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
    /// Windows, as administrator: scans read the disk's file table. The UI
    /// tests turn it off, to check the folder walk whoever runs them.
    mft: bool = true,
    /// Docker asked through its command line. The UI tests turn it off:
    /// whether Docker is there, running and quick is the machine's.
    docker: bool = true,
    /// Counts scans: what a removal was asked about must still be there.
    generation: u32 = 0,
    /// What the rules found in the tree, and those nodes as a set (the map's
    /// marks).
    finds: []const rules.Find = &.{},
    found: std.DynamicBitSetUnmanaged = .{},
    marks_shown: bool = false,
    /// Where snapshots are kept (null: not kept); what changed since the
    /// scanned folder's previous scan, in its own arena.
    data_dir: ?[]const u8 = null,
    changes: ?snapshot.Changes = null,
    changes_arena: ?std.heap.ArenaAllocator = null,
    /// The last duplicate search's groups (gpa), for the tree of `generation`.
    duplicate_groups: []const dupes.Group = &.{},

    /// Set by main.zig: the tray, notifications and the window are its.
    plume_app: ?*plume.App = null,
    /// Where "watch free space" is remembered (null: not remembered).
    settings_path: ?[]const u8 = null,
    /// Watching free space: the tray icon, there while it is on.
    tray: ?*plume.Tray = null,
    /// The tray's popover (tray.html), shown by the icon on a click; made
    /// once, hidden when not shown.
    popover: ?*plume.Window = null,
    /// The disks told already that they are nearly full (until they have
    /// room again), by path.
    alarmed: std.ArrayList([]u8) = .empty,
    /// Below this percent of a disk free, the alarm (the meter's red zone
    /// is the last tenth).
    alarm_percent: u8 = 10,

    const gpa = std.heap.smp_allocator;

    /// The app is ending: a scan still running stops now (app.deinit waits
    /// for it, and a whole disk takes minutes).
    pub fn stop(self: *App) void {
        self.cancelScan();
    }

    pub fn deinit(self: *App) void {
        if (self.layout) |*l| l.deinit(gpa);
        if (self.tree) |*t| t.deinit(gpa);
        gpa.free(self.finds);
        self.found.deinit(gpa);
        if (self.changes_arena) |*arena| arena.deinit();
        dupes.free(gpa, self.duplicate_groups);
        for (self.alarmed.items) |path| gpa.free(path);
        self.alarmed.deinit(gpa);
    }

    /// The disks there are to scan, with their space.
    pub fn disks(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}![]const disk_list.Disk {
        return disk_list.list(allocator, self.io);
    }

    /// Below what percent free a disk raises the alarm.
    pub fn alarm(self: *App) u8 {
        return self.alarm_percent;
    }

    /// The alarm's threshold (1 to 50 percent), remembered.
    pub fn setAlarm(self: *App, percent: u8) void {
        self.alarm_percent = std.math.clamp(percent, 1, 50);
        for (self.alarmed.items) |path| gpa.free(path);
        self.alarmed.clearRetainingCapacity();
        self.saveSettings();
        self.watchTick();
    }

    /// What changed since the previous scan of `tree`'s folder (kept in a
    /// file per folder), then this scan kept for the next one.
    fn compareAndKeep(self: *App, tree: *const scanner.Tree) ?struct { arena: std.heap.ArenaAllocator, changes: ?snapshot.Changes } {
        const dir = self.data_dir orelse return null;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const a = arena.allocator();
        const folder = std.fs.path.join(a, &.{ dir, "snapshots" }) catch return null;
        const file = snapshot.fileFor(a, folder, tree.root) catch return null;
        const cwd = std.Io.Dir.cwd();
        var changes: ?snapshot.Changes = null;
        if (cwd.readFileAlloc(self.io, file, a, .limited(64 * 1024 * 1024))) |bytes| {
            if (snapshot.parse(a, bytes)) |old| {
                changes = snapshot.diff(a, &old, tree) catch null;
            } else |_| {}
        } else |_| {}
        const now = std.Io.Clock.real.now(self.io).toMilliseconds();
        if (snapshot.take(a, tree, now)) |bytes| {
            cwd.createDirPath(self.io, folder) catch {};
            cwd.writeFile(self.io, .{ .sub_path = file, .data = bytes }) catch {};
        } else |_| {}
        return .{ .arena = arena, .changes = changes };
    }

    /// What changed since the previous scan of this folder; null on its
    /// first scan.
    pub fn changed(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}!?Changed {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return null);
        const c = self.changes orelse return null;
        const lists = [2][]const snapshot.Change{ c.grew, c.shrank };
        var out: [2][]Moved = undefined;
        for (lists, &out) |list, *moved| {
            const kept = list[0..@min(list.len, 15)];
            moved.* = try allocator.alloc(Moved, kept.len);
            for (kept, moved.*) |change, *m| m.* = .{
                .path = try allocator.dupe(u8, change.path),
                .before = change.before,
                .after = change.after,
                .node = change.node,
                .parent = if (change.node) |n| tree.node(n).parent else null,
            };
        }
        return .{ .since_ms = c.since_ms, .before = c.before, .after = c.after, .grew = out[0], .shrank = out[1] };
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
    pub fn scan(self: *App, allocator: std.mem.Allocator, path: []const u8) (scanner.Error || wsl.Error || error{Busy})!Scanned {
        return self.scanFrom(allocator, .{ .folder = path });
    }

    /// Everything inside the WSL distribution `name` (its own find lists
    /// it), shown as a scan; what goes is deleted through WSL's share.
    pub fn scanDistro(self: *App, allocator: std.mem.Allocator, name: []const u8) (scanner.Error || wsl.Error || error{Busy})!Scanned {
        return self.scanFrom(allocator, .{ .distro = name });
    }

    const Source = union(enum) { folder: []const u8, distro: []const u8 };

    fn scanFrom(self: *App, allocator: std.mem.Allocator, source: Source) (scanner.Error || wsl.Error || error{Busy})!Scanned {
        if (self.scanning.swap(true, .acq_rel)) return error.Busy;
        defer self.scanning.store(false, .release);
        self.cancel.store(false, .monotonic);
        self.scan_used = switch (source) {
            .folder => |path| if (volume.space(gpa, path)) |s| s.total - s.free else 0,
            .distro => |name| distroSize(name),
        };
        self.map.setActivity(4, 2.6, 0);
        defer self.map.setActivity(idle_detail, 1, 0);

        const start = std.Io.Clock.awake.now(self.io);
        const progress: scanner.Report = .{ .context = self, .call = report };
        var tree = switch (source) {
            .folder => |path| try scanner.scan(gpa, self.io, path, .{ .report = progress, .cancel = &self.cancel, .mft = self.mft }),
            .distro => |name| try wsl.scanDistro(gpa, self.io, name, progress, &self.cancel),
        };
        const ms = start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
        // What can go, while still on the scan's thread (tens of ms).
        const finds: []const rules.Find = rules.find(gpa, &tree, scanner.Tree.root_index) catch &.{};
        var found = std.DynamicBitSetUnmanaged.initEmpty(gpa, tree.nodes.items.len) catch std.DynamicBitSetUnmanaged{};
        if (found.bit_length > 0) for (finds) |f| found.set(f.node);
        // What changed since this folder's last scan; this one kept.
        const compared = self.compareAndKeep(&tree);
        const top = tree.node(scanner.Tree.root_index);
        const result: Scanned = .{
            .path = try allocator.dupe(u8, tree.root),
            .size = top.size,
            .files = top.files,
            .entries = tree.nodes.items.len,
            .unreadable = tree.unreadable,
            .ms = @intCast(@max(ms, 0)),
            .from_mft = tree.from_mft,
            .wsl = source == .distro,
        };

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.layout) |*l| l.deinit(gpa);
        self.layout = null;
        if (self.tree) |*t| t.deinit(gpa);
        self.tree = tree;
        gpa.free(self.finds);
        self.finds = finds;
        self.found.deinit(gpa);
        self.found = found;
        if (self.changes_arena) |*arena| arena.deinit();
        self.changes_arena = null;
        self.changes = null;
        if (compared) |c| {
            self.changes_arena = c.arena;
            self.changes = c.changes;
        }
        // The duplicates found were the old tree's.
        dupes.free(gpa, self.duplicate_groups);
        self.duplicate_groups = &.{};
        self.generation +%= 1;
        self.root = scanner.Tree.root_index;
        self.legend_root = null;
        self.map.clear();
        return result;
    }

    /// Files with the same bytes (a megabyte and up) in the last scan, read
    /// on a worker thread: "duplicates" events while it runs. Cancel with
    /// cancelScan.
    pub fn findDuplicates(self: *App, allocator: std.mem.Allocator) error{ NoScan, Busy, Canceled, OutOfMemory }!Dupes {
        if (self.tree == null) return error.NoScan;
        // Holds the tree: no scan replaces it meanwhile.
        if (self.scanning.swap(true, .acq_rel)) return error.Busy;
        defer self.scanning.store(false, .release);
        self.cancel.store(false, .monotonic);
        const Relay = struct {
            fn call(context: *anyopaque, progress: dupes.DupesProgress) void {
                const app: *App = @ptrCast(@alignCast(context));
                if (app.events) |events| events.emit(.duplicates, progress);
            }
        };
        const found = try dupes.find(gpa, self.io, &self.tree.?, scanner.Tree.root_index, .{
            .report = .{ .context = self, .call = Relay.call },
            .cancel = &self.cancel,
        });
        self.lock.lockUncancelable(self.io);
        dupes.free(gpa, self.duplicate_groups);
        self.duplicate_groups = found;
        self.lock.unlock(self.io);
        return (try self.duplicates(allocator)).?;
    }

    /// The last search's duplicates, without what was deleted since; null
    /// before a search of this scan.
    pub fn duplicates(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}!?Dupes {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return null);
        var groups: std.ArrayList(DupeGroup) = .empty;
        var wasted: u64 = 0;
        for (self.duplicate_groups) |g| {
            var copies: std.ArrayList(DupeCopy) = .empty;
            for (g.nodes) |node| {
                if (tree.node(node).size == 0 or gone(tree, node)) continue;
                try copies.append(allocator, .{
                    .node = node,
                    .name = tree.name(node),
                    .path = try relative(allocator, tree, node),
                    .parent = tree.node(node).parent,
                    .mtime = tree.node(node).mtime,
                });
            }
            if (copies.items.len < 2) continue;
            const w = g.size * (copies.items.len - 1);
            wasted += w;
            try groups.append(allocator, .{ .size = g.size, .wasted = w, .copies = copies.items });
        }
        return .{ .groups = groups.items, .wasted = wasted, .generation = self.generation };
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

    /// WSL's distributions and their virtual disks, largest first (none off
    /// Windows).
    pub fn distros(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}![]const Distro {
        _ = self;
        return wsl.list(allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => &.{},
        };
    }

    /// The distribution `name`'s virtual disk compacted, so Windows gets back
    /// what was freed inside it. Stops WSL (every distribution) first;
    /// administrator only. Minutes for a large disk.
    pub fn compactDistro(self: *App, allocator: std.mem.Allocator, name: []const u8) (wsl.Error || error{ NotAdmin, NotFound, Busy })!Compacted {
        if (!elevate.isAdmin()) return error.NotAdmin;
        const found = for (try wsl.list(allocator)) |d| {
            if (std.mem.eql(u8, d.name, name)) break d;
        } else return error.NotFound;
        if (self.scanning.swap(true, .acq_rel)) return error.Busy;
        defer self.scanning.store(false, .release);
        const after = try wsl.compact(allocator, self.io, found);
        return .{ .before = found.size, .after = after };
    }

    /// What Docker's images, containers, build cache and volumes take.
    pub fn dockerUsage(self: *App, allocator: std.mem.Allocator) docker.Error!DockerUsage {
        if (!self.docker) return error.NoDocker;
        return docker.usage(allocator, self.io);
    }

    /// Runs a prune (stopped containers, unused images, the build cache);
    /// what Docker reclaimed, in bytes. Volumes are never pruned.
    pub fn dockerPrune(self: *App, allocator: std.mem.Allocator, what: DockerPrune) docker.Error!u64 {
        if (!self.docker) return error.NoDocker;
        return docker.prune(allocator, self.io, what);
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
        const marks = try self.marksFor(tree, &self.layout.?);
        defer gpa.free(marks);
        try self.map.show(gpa, &self.layout.?, zoom, marks);

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

    /// Per item of `layout`: 2 what the rules found, 1 inside it, 0 the rest.
    fn marksFor(self: *App, tree: *const scanner.Tree, layout: *const treemap.Layout) ![]u8 {
        const marks = try gpa.alloc(u8, layout.items.items.len);
        @memset(marks, 0);
        if (self.found.bit_length != tree.nodes.items.len) return marks;
        for (layout.items.items, marks) |item, *mark| {
            if (item.shape != .rest and self.found.isSet(item.node)) {
                mark.* = 2;
                continue;
            }
            // Inside a match (the view itself may be inside one).
            var at = item.node;
            while (true) {
                if (self.found.isSet(at)) {
                    mark.* = 1;
                    break;
                }
                if (at == 0) break;
                at = tree.node(at).parent;
            }
        }
        return marks;
    }

    /// What the rules found in the last scan, grouped, biggest first; what
    /// was deleted since is left out.
    pub fn reclaimable(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}!?Reclaim {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return null);

        // One group per rule id (several rules share one).
        var groups: std.ArrayList(Group) = .empty;
        var places: std.ArrayList(std.ArrayList(Place)) = .empty;
        var total: u64 = 0;
        var careful: u64 = 0;
        for (self.finds) |f| {
            const n = tree.node(f.node);
            if (n.size == 0 or gone(tree, f.node)) continue;
            const rule = rules.rules[f.rule];
            const g = for (groups.items, 0..) |group, i| {
                if (std.mem.eql(u8, group.id, rule.id)) break i;
            } else blk: {
                try groups.append(allocator, .{ .id = rule.id, .title = rule.title, .why = rule.why, .risk = rule.risk, .action = rule.action, .command = rule.command, .size = 0, .count = 0, .items = &.{}, .nodes = &.{} });
                try places.append(allocator, .empty);
                break :blk groups.items.len - 1;
            };
            groups.items[g].size += n.size;
            groups.items[g].count += 1;
            if (rule.risk == .careful or rule.action == .show or rule.action == .command) careful += n.size else total += n.size;
            try places.items[g].append(allocator, .{ .node = f.node, .path = "", .size = n.size, .parent = n.parent });
        }
        const bySize = struct {
            fn group(_: void, l: Group, r: Group) bool {
                return l.size > r.size;
            }
            fn place(_: void, l: Place, r: Place) bool {
                return l.size > r.size;
            }
        };
        for (groups.items, places.items) |*group, *list| {
            std.mem.sort(Place, list.items, {}, bySize.place);
            const nodes = try allocator.alloc(u32, list.items.len);
            for (list.items, nodes) |place, *n| n.* = place.node;
            group.nodes = nodes;
            const kept = list.items[0..@min(list.items.len, 40)];
            for (kept) |*place| place.path = try relative(allocator, tree, place.node);
            group.items = kept;
        }
        std.mem.sort(Group, groups.items, {}, bySize.group);
        return .{ .size = total, .careful = careful, .groups = groups.items, .generation = self.generation };
    }

    /// The projects in the last scan untouched for `days` that hold what
    /// can go, largest first; null before a scan.
    pub fn stale(self: *App, allocator: std.mem.Allocator, days: u32) error{OutOfMemory}!?Stale {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return null);
        const now = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
        const cutoff = now - @as(i64, days) * 24 * 3600;
        const found = try projects.stale(allocator, tree, scanner.Tree.root_index, self.finds, cutoff);
        const list = try allocator.alloc(StaleProject, found.len);
        var total: u64 = 0;
        for (found, list) |p, *out| {
            const items = try allocator.alloc(Place, p.finds.len);
            for (p.finds, items) |node, *item| {
                item.* = .{ .node = node, .path = try relative(allocator, tree, node), .size = tree.node(node).size, .parent = tree.node(node).parent };
            }
            out.* = .{
                .node = p.node,
                .name = tree.name(p.node),
                .path = try relative(allocator, tree, p.node),
                .parent = tree.node(p.node).parent,
                .last_touched = p.last_touched,
                .size = p.size,
                .items = items,
                .nodes = p.finds,
            };
            total += p.size;
        }
        return .{ .projects = list, .size = total, .cutoff = cutoff, .generation = self.generation };
    }

    /// What the rules found shown on the map (the rest dimmed), or not.
    pub fn showReclaimable(self: *App, on: bool) void {
        self.marks_shown = on;
        self.map.showMarks(on);
    }

    /// `node` lit on the map, if it is drawn (the panel's item under the mouse).
    pub fn highlight(self: *App, node: u32) bool {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const layout = &(self.layout orelse return false);
        for (layout.items.items, 0..) |item, i| {
            if (item.node == node and item.shape != .rest) {
                self.map.hover(i);
                return true;
            }
        }
        self.map.hover(null);
        return false;
    }

    /// Deletes several items (a group of what can go), one after another,
    /// on a worker thread; refused ones and failures are counted.
    pub fn removeMany(self: *App, allocator: std.mem.Allocator, nodes: []const u32, generation: u32, mode: removing.Mode) error{ NoScan, Stale }!Cleaned {
        var cleaned: Cleaned = .{ .size = 0, .count = 0, .failed = 0, .reason = null };
        for (nodes) |node| {
            const removed = self.remove(node, generation, mode) catch |err| switch (err) {
                error.NoScan => return error.NoScan,
                error.Stale => return error.Stale,
                else => {
                    cleaned.failed += 1;
                    if (cleaned.reason == null) cleaned.reason = allocator.dupe(u8, @errorName(err)) catch null;
                    continue;
                },
            };
            cleaned.size += removed.size;
            cleaned.count += 1;
        }
        return cleaned;
    }

    /// Empties the Recycle Bin (Windows) or the Trash (Linux) that `node` is,
    /// on a worker thread, then measures that folder again.
    pub fn emptyBin(self: *App, node: u32, generation: u32) (removing.Error || scanner.Error || error{ NoScan, Stale })!Removed {
        const path = blk: {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            const tree = &(self.tree orelse return error.NoScan);
            if (generation != self.generation or node >= tree.nodes.items.len) return error.Stale;
            break :blk try tree.path(gpa, node);
        };
        defer gpa.free(path);
        try removing.emptyBin(gpa, self.io, path);
        return self.refresh(node, generation, path);
    }

    /// `node` measured again (after something outside Headroom changed it):
    /// the folders above take the difference, and it is drawn as one tile.
    /// Walked folder by folder: the disk's file table, read from the disk,
    /// may not have a change of a moment ago yet.
    fn refresh(self: *App, node: u32, generation: u32, path: []const u8) (scanner.Error || error{ NoScan, Stale })!Removed {
        var again = scanner.scan(gpa, self.io, path, .{ .mft = false }) catch |err| switch (err) {
            error.FileNotFound => scanner.Tree{ .root = try gpa.dupeSentinel(u8, path, 0) },
            else => return err,
        };
        defer again.deinit(gpa);
        const now: scanner.Node = if (again.nodes.items.len > 0) again.node(0) else .{ .parent = 0, .name_start = 0, .name_len = 0, .kind = .directory, .size = 0, .files = 0 };

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return error.NoScan);
        if (generation != self.generation) return error.Stale;
        const n = &tree.nodes.items[node];
        const freed: Removed = .{ .size = n.size -| now.size, .files = n.files -| now.files };
        n.size = now.size;
        n.files = now.files;
        n.child_count = 0;
        var at = n.parent;
        while (true) : (at = tree.nodes.items[at].parent) {
            const parent = &tree.nodes.items[at];
            parent.size -|= freed.size;
            parent.files -|= freed.files;
            if (at == 0 or node == 0) break;
        }
        self.legend_root = null;
        return freed;
    }

    pub const Found = struct {
        node: u32,
        name: []const u8,
        /// From the folder scanned.
        path: []const u8,
        size: u64,
        folder: bool,
        /// Where the map goes for it.
        parent: u32,
    };

    /// Entries whose name holds `query` (any case), the biggest first, at
    /// most 50.
    pub fn search(self: *App, allocator: std.mem.Allocator, query: []const u8) error{OutOfMemory}![]const Found {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return &.{});
        const q = std.mem.trim(u8, query, " ");
        if (q.len < 2) return &.{};
        const limit = 50;
        // The biggest matches kept, smallest last.
        var best: std.ArrayList(u32) = .empty;
        defer best.deinit(gpa);
        for (tree.nodes.items[1..], 1..) |n, i| {
            if (n.size == 0) continue;
            if (best.items.len == limit and n.size <= tree.node(best.items[limit - 1]).size) continue;
            if (std.ascii.findIgnoreCase(tree.name(@intCast(i)), q) == null) continue;
            const at = for (best.items, 0..) |b, k| {
                if (n.size > tree.node(b).size) break k;
            } else best.items.len;
            try best.insert(gpa, at, @intCast(i));
            if (best.items.len > limit) _ = best.pop();
        }
        const out = try allocator.alloc(Found, best.items.len);
        for (best.items, out) |node, *f| {
            const n = tree.node(node);
            f.* = .{
                .node = node,
                .name = try allocator.dupe(u8, tree.name(node)),
                .path = try relative(allocator, tree, node),
                .size = n.size,
                .folder = n.kind == .directory,
                .parent = n.parent,
            };
        }
        return out;
    }

    pub const Entry = struct {
        node: u32,
        name: []const u8,
        kind: Kind,
        size: u64,
        files: u64,
        /// The legend's color for a file; null for folders and the rest.
        color: ?[]const u8,
        opens: bool,
    };

    /// What `node` holds, the biggest first (the list beside the map), at
    /// most 1,000.
    pub fn entries(self: *App, allocator: std.mem.Allocator, node: u32) error{ NoScan, OutOfMemory }![]const Entry {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return error.NoScan);
        if (node >= tree.nodes.items.len) return &.{};
        const n = tree.node(node);
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        for (tree.children(node), 0..) |child, i| {
            if (child.size == 0) continue;
            try order.append(gpa, n.first_child + @as(u32, @intCast(i)));
        }
        std.mem.sort(u32, order.items, tree, struct {
            fn bigger(t: *const scanner.Tree, l: u32, r: u32) bool {
                return t.node(l).size > t.node(r).size;
            }
        }.bigger);
        const kept = order.items[0..@min(order.items.len, 1000)];
        const out = try allocator.alloc(Entry, kept.len);
        for (kept, out) |index, *e| {
            const c = tree.node(index);
            const file = c.kind == .file;
            e.* = .{
                .node = index,
                .name = try allocator.dupe(u8, tree.name(index)),
                .kind = switch (c.kind) {
                    .directory => .folder,
                    .file => .file,
                    .link => .link,
                    .mount => .mount,
                    .other => .other,
                },
                .size = c.size,
                .files = c.files,
                .color = if (file) try hex(allocator, categories.info.get(categories.of(tree.name(index))).color) else null,
                .opens = c.kind == .directory and c.child_count > 0,
            };
        }
        return out;
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

    /// The home disk's headroom on the tray, and the alarm for any fixed
    /// disk once it is nearly full. The page calls it every minute.
    pub fn watchTick(self: *App) void {
        const tray = self.tray orelse return;
        const app = self.plume_app orelse return;
        if (volume.space(gpa, self.home_path)) |s| if (s.total > 0) {
            const free_share = @as(f64, @floatFromInt(s.free)) / @as(f64, @floatFromInt(s.total));
            var free_text: [32]u8 = undefined;
            var level: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&level, "{s} free on {s} ({d:.0}%)", .{ human(&free_text, s.free), driveOf(self.home_path), free_share * 100 }) catch return;
            var tip: [128]u8 = undefined;
            tray.setTooltip(std.fmt.bufPrint(&tip, "Headroom: {s}", .{label}) catch label) catch {};
            tray.setMenu(&trayMenu(label, app.startsAtLogin())) catch {};
        };

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const all = disk_list.list(arena.allocator(), self.io) catch return;
        const below = @as(f64, @floatFromInt(self.alarm_percent)) / 100;
        for (all) |d| {
            if (d.removable or d.total == 0) continue;
            const free_share = @as(f64, @floatFromInt(d.free)) / @as(f64, @floatFromInt(d.total));
            const told = for (self.alarmed.items, 0..) |path, i| {
                if (std.mem.eql(u8, path, d.path)) break i;
            } else null;
            if (free_share < below and told == null) {
                const path = gpa.dupe(u8, d.path) catch continue;
                self.alarmed.append(gpa, path) catch {
                    gpa.free(path);
                    continue;
                };
                var free_text: [32]u8 = undefined;
                var title: [96]u8 = undefined;
                var body: [192]u8 = undefined;
                app.notify(.{
                    .title = std.fmt.bufPrint(&title, "{s} is almost full", .{d.path}) catch "A disk is almost full",
                    .body = std.fmt.bufPrint(&body, "{s} of headroom left ({d:.0}%). Open Headroom to see what fills it.", .{ human(&free_text, d.free), free_share * 100 }) catch null,
                    .tag = "headroom-low",
                }) catch {};
            } else if (free_share > below + 0.01) if (told) |i| {
                gpa.free(self.alarmed.swapRemove(i));
            };
        }
    }

    /// main.zig: the tray, when watching was on last time. A click on its
    /// icon shows the popover (tray.html), a right click the menu.
    pub fn startWatching(self: *App) !void {
        const app = self.plume_app orelse return error.Unsupported;
        const tray = try app.createTray(.{ .tooltip = "Headroom", .menu = &trayMenu("Headroom", app.startsAtLogin()) });
        errdefer app.destroyTray(tray);
        if (self.popover == null) {
            const popover = try app.openWindow(.{
                .title = "Headroom",
                .url = "tray.html",
                .width = 340,
                .height = 540,
                .frameless = true,
                .transparent = true,
                .resizable = false,
                .hidden = true,
            });
            // Closing it (Alt+F4) hides it: it is made once.
            const Keep = struct {
                fn close(s: *App) bool {
                    if (s.popover) |p| p.hide() catch {};
                    return false;
                }
            };
            popover.onClose(self, Keep.close);
            self.popover = popover;
        }
        tray.attachWindow(self.popover);
        self.tray = tray;
        self.watchTick();
    }

    fn stopWatching(self: *App) void {
        const app = self.plume_app orelse return;
        if (self.popover) |popover| popover.hide() catch {};
        if (self.tray) |tray| app.destroyTray(tray);
        self.tray = null;
        for (self.alarmed.items) |path| gpa.free(path);
        self.alarmed.clearRetainingCapacity();
    }

    pub const Top = struct { name: []const u8, size: u64, folder: bool };

    /// The biggest entries of the folder scanned, biggest first (the
    /// popover's list); empty before a scan.
    pub fn largest(self: *App, allocator: std.mem.Allocator, count: u32) error{OutOfMemory}![]const Top {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = &(self.tree orelse return &.{});
        var out: std.ArrayList(Top) = .empty;
        for (tree.children(0), 0..) |child, i| {
            if (child.size == 0) continue;
            const index = tree.node(0).first_child + @as(u32, @intCast(i));
            try out.append(allocator, .{ .name = try allocator.dupe(u8, tree.name(index)), .size = child.size, .folder = child.kind == .directory });
        }
        std.mem.sort(Top, out.items, {}, struct {
            fn bigger(_: void, l: Top, r: Top) bool {
                return l.size > r.size;
            }
        }.bigger);
        return out.items[0..@min(out.items.len, count)];
    }

    /// The folder last scanned, null before a scan.
    pub fn scannedPath(self: *App, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const tree = self.tree orelse return null;
        return try allocator.dupe(u8, tree.root);
    }

    /// The main window, shown and focused (the popover hides).
    pub fn openMain(self: *App) void {
        if (self.popover) |popover| popover.hide() catch {};
        self.menuChosen("open");
    }

    /// From the popover: the main window scans `path`.
    pub fn requestScan(self: *App, path: []const u8) void {
        self.openMain();
        if (self.events) |events| events.emit(.request_scan, path);
    }

    /// The popover hides (Escape in it).
    pub fn hidePopover(self: *App) void {
        if (self.popover) |popover| popover.hide() catch {};
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
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{{\"watch\":{},\"alarm\":{d}}}\n", .{ self.tray != null, self.alarm_percent }) catch return;
        cwd.writeFile(self.io, .{ .sub_path = path, .data = text }) catch {};
    }

    pub const Saved = struct { watch: bool = false, alarm: u8 = 10 };

    /// main.zig: what was set last time.
    pub fn saved(io: std.Io, path: []const u8) Saved {
        var buffer: [256]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return .{};
        var result: Saved = .{ .watch = std.mem.indexOf(u8, text, "\"watch\":true") != null };
        if (std.mem.indexOf(u8, text, "\"alarm\":")) |at| {
            const rest = text[at + "\"alarm\":".len ..];
            const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
            result.alarm = std.math.clamp(std.fmt.parseInt(u8, rest[0..end], 10) catch 10, 1, 50);
        }
        return result;
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

/// What the distribution `name`'s virtual disk takes (0 if unknown): how
/// far a scan of it has come.
fn distroSize(name: []const u8) u64 {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const list = wsl.list(arena.allocator()) catch return 0;
    for (list) |d| if (std.mem.eql(u8, d.name, name)) return d.size;
    return 0;
}

/// Whether `node` or a folder above it was deleted (its size taken away).
fn gone(tree: *const scanner.Tree, node: u32) bool {
    var at = tree.node(node).parent;
    while (at != 0) : (at = tree.node(at).parent) {
        if (tree.node(at).size == 0) return true;
    }
    return false;
}

/// `node`'s path from the folder scanned, "/" between folders.
fn relative(allocator: std.mem.Allocator, tree: *const scanner.Tree, node: u32) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var at = node;
    while (at != 0) : (at = tree.node(at).parent) try parts.append(allocator, tree.name(at));
    std.mem.reverse([]const u8, parts.items);
    return std.mem.join(allocator, std.fs.path.sep_str, parts.items);
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
