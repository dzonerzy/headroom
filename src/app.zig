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

pub const App = struct {
    pub const async_methods = .{"scan"};

    pub const Events = struct {
        progress: Progress,
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

    io: std.Io,
    home_path: []const u8,
    map: *map_layer.Map,
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

    const gpa = std.heap.smp_allocator;

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

    /// Everything under `path`, on a worker thread: "progress" events while
    /// it runs. Then view(0, ...) shows it.
    pub fn scan(self: *App, allocator: std.mem.Allocator, path: []const u8) (scanner.Error || error{Busy})!Scanned {
        if (self.scanning.swap(true, .acq_rel)) return error.Busy;
        defer self.scanning.store(false, .release);
        self.cancel.store(false, .monotonic);

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
        self.root = scanner.Tree.root_index;
        self.legend_root = null;
        self.map.clear();
        return result;
    }

    fn report(context: *anyopaque, progress: scanner.Progress) void {
        const self: *App = @ptrCast(@alignCast(context));
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
