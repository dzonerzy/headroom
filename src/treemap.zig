//! The nested treemap: a folder's rectangle shared among what it holds by
//! size (squarified: tiles as square as they can be), folders opened all the
//! way down while there is room, each a frame with a header strip for its
//! name. What is too small to see is gathered into one tile per folder.
//!
//! Pixels (CSS), for the folder being looked at: only what is seen is laid
//! out, so a tree of millions costs what the screen holds.

const std = @import("std");
const scan = @import("scan.zig");
const categories = @import("categories.zig");
const Allocator = std.mem.Allocator;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }
};

pub const Shape = enum(u8) {
    /// An opened folder: a frame, its contents inside.
    folder,
    /// A folder with no room to open: one tile.
    closed,
    file,
    /// What was too small to show in a folder, together.
    rest,
};

pub const Item = struct {
    rect: Rect,
    /// The tree's node; for `rest`, the folder it is in.
    node: u32,
    shape: Shape,
    depth: u8,
    category: categories.Category = .other,
    /// A folder frame with a header strip (room for its name).
    header: bool = false,
    /// For `rest`: how many items, and their size.
    count: u32 = 0,
    size: u64 = 0,
};

pub const Label = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    node: u32,
    shape: Shape,
    /// Empty for `rest` ("N smaller items": the page writes it).
    name: []const u8,
    size: u64,
    count: u32,
    depth: u8,
};

pub const Options = struct {
    header: f32 = 18,
    padding: f32 = 3,
    /// Smaller tiles than this (square pixels) go into the folder's rest.
    min_area: f32 = 10,
    /// A folder opens when its tile is at least this wide and high.
    open_width: f32 = 26,
    open_height: f32 = 22,
    /// Labels on tiles at least this big; on headers this wide.
    label_width: f32 = 46,
    label_height: f32 = 30,
    max_labels: usize = 2000,
};

pub const Layout = struct {
    items: std.ArrayList(Item) = .empty,
    labels: std.ArrayList(Label) = .empty,
    bounds: Rect,

    pub fn deinit(self: *Layout, a: Allocator) void {
        self.items.deinit(a);
        self.labels.deinit(a);
    }

    /// The deepest item under (x, y): items come after the folder they are in.
    pub fn hit(self: *const Layout, x: f32, y: f32) ?usize {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].rect.contains(x, y)) return i;
        }
        return null;
    }

    /// Where `node` is drawn, if it is.
    pub fn find(self: *const Layout, node: u32) ?Rect {
        for (self.items.items) |item| {
            if (item.node == node and item.shape != .rest) return item.rect;
        }
        return null;
    }
};

/// `root`'s contents laid out in `bounds`.
pub fn layout(a: Allocator, tree: *const scan.Tree, root: u32, bounds: Rect, options: Options) Allocator.Error!Layout {
    var result: Layout = .{ .bounds = bounds };
    errdefer result.deinit(a);
    var builder: Builder = .{ .a = a, .tree = tree, .options = options, .out = &result };
    defer builder.order.deinit(a);
    defer builder.areas.deinit(a);
    defer builder.rects.deinit(a);
    try builder.contents(root, bounds, 0);
    return result;
}

const Builder = struct {
    a: Allocator,
    tree: *const scan.Tree,
    options: Options,
    out: *Layout,
    // Scratch, reused level to level (each level copies what it keeps).
    order: std.ArrayList(u32) = .empty,
    areas: std.ArrayList(f32) = .empty,
    rects: std.ArrayList(Rect) = .empty,

    fn label(b: *Builder, l: Label) Allocator.Error!void {
        if (b.out.labels.items.len < b.options.max_labels) try b.out.labels.append(b.a, l);
    }

    /// A folder's frame, then its contents.
    fn folder(b: *Builder, node: u32, rect: Rect, depth: u8) Allocator.Error!void {
        const o = b.options;
        const header = rect.h >= o.header + 14 and rect.w >= 30;
        try b.out.items.append(b.a, .{ .rect = rect, .node = node, .shape = .folder, .depth = depth, .header = header });
        if (header and rect.w >= o.label_width) {
            try b.label(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = o.header, .node = node, .shape = .folder, .name = b.tree.name(node), .size = b.tree.node(node).size, .count = 0, .depth = depth });
        }
        const pad: f32 = if (header) o.padding else 1;
        const top: f32 = if (header) o.header else 1;
        try b.contents(node, .{ .x = rect.x + pad, .y = rect.y + top, .w = rect.w - 2 * pad, .h = rect.h - top - pad }, depth);
    }

    /// What `node` holds, in `inner`.
    fn contents(b: *Builder, node: u32, inner: Rect, depth: u8) Allocator.Error!void {
        const o = b.options;
        if (inner.w < 2 or inner.h < 2) return;
        const tree = b.tree;
        const first = tree.node(node).first_child;

        // Its children with a size, biggest first.
        const start = b.order.items.len;
        defer b.order.shrinkRetainingCapacity(start);
        var total: u64 = 0;
        for (tree.children(node), 0..) |child, i| {
            if (child.size == 0) continue;
            try b.order.append(b.a, first + @as(u32, @intCast(i)));
            total += child.size;
        }
        const kids = b.order.items[start..];
        if (kids.len == 0 or total == 0) return;
        std.mem.sort(u32, kids, tree, struct {
            fn bigger(t: *const scan.Tree, l: u32, r: u32) bool {
                return t.node(l).size > t.node(r).size;
            }
        }.bigger);

        // The tail too small to see goes into one rest tile.
        const scale = inner.w * inner.h / @as(f32, @floatFromInt(total));
        var shown = kids.len;
        while (shown > 0 and @as(f32, @floatFromInt(tree.node(kids[shown - 1]).size)) * scale < o.min_area) shown -= 1;
        if (kids.len - shown == 1) shown = kids.len;
        var rest_size: u64 = 0;
        for (kids[shown..]) |k| rest_size += tree.node(k).size;
        const tiles = shown + @intFromBool(rest_size > 0);

        const area_start = b.areas.items.len;
        defer b.areas.shrinkRetainingCapacity(area_start);
        const rect_start = b.rects.items.len;
        defer b.rects.shrinkRetainingCapacity(rect_start);
        for (kids[0..shown]) |k| try b.areas.append(b.a, @as(f32, @floatFromInt(tree.node(k).size)) * scale);
        if (rest_size > 0) try b.areas.append(b.a, @as(f32, @floatFromInt(rest_size)) * scale);
        try b.rects.resize(b.a, rect_start + tiles);
        squarify(b.areas.items[area_start..][0..tiles], inner, b.rects.items[rect_start..][0..tiles]);

        for (0..shown) |i| {
            // Copied: deeper levels grow the scratch lists.
            const k = b.order.items[start + i];
            const rect = b.rects.items[rect_start + i];
            const n = tree.node(k);
            const child_depth = depth +| 1;
            if (n.kind == .directory and n.child_count > 0 and rect.w >= o.open_width and rect.h >= o.open_height) {
                try b.folder(k, rect, child_depth);
                continue;
            }
            const shape: Shape = if (n.kind == .directory) .closed else .file;
            try b.out.items.append(b.a, .{
                .rect = rect,
                .node = k,
                .shape = shape,
                .depth = child_depth,
                .category = if (shape == .file) categories.of(tree.name(k)) else .other,
            });
            if (rect.w >= o.label_width and rect.h >= o.label_height) {
                try b.label(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .node = k, .shape = shape, .name = tree.name(k), .size = n.size, .count = 0, .depth = child_depth });
            }
        }
        if (rest_size > 0) {
            const rect = b.rects.items[rect_start + shown];
            const count: u32 = @intCast(kids.len - shown);
            try b.out.items.append(b.a, .{ .rect = rect, .node = node, .shape = .rest, .depth = depth +| 1, .count = count, .size = rest_size });
            if (rect.w >= o.label_width and rect.h >= o.label_height) {
                try b.label(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .node = node, .shape = .rest, .name = "", .size = rest_size, .count = count, .depth = depth +| 1 });
            }
        }
    }
};

/// Squarified layout (Bruls, Huizing, van Wijk): `areas` (biggest first,
/// summing to the rectangle's area) in rows along the shorter side, each row
/// grown while its tiles get closer to square.
pub fn squarify(areas: []const f32, bounds: Rect, out: []Rect) void {
    var r = bounds;
    var i: usize = 0;
    while (i < areas.len) {
        const side = @max(@min(r.w, r.h), 0.0001);
        var j = i;
        var sum: f32 = 0;
        var best = std.math.inf(f32);
        while (j < areas.len) {
            const s = sum + areas[j];
            const worst = worstRatio(areas[i], areas[j], s, side);
            if (j > i and worst > best) break;
            best = worst;
            sum = s;
            j += 1;
        }
        const thickness = if (sum > 0) sum / side else 0;
        var along: f32 = 0;
        if (r.w >= r.h) {
            // A column on the left.
            for (areas[i..j], out[i..j]) |area, *o| {
                const length = if (thickness > 0) area / thickness else 0;
                o.* = .{ .x = r.x, .y = r.y + along, .w = thickness, .h = length };
                along += length;
            }
            r.x += thickness;
            r.w = @max(r.w - thickness, 0);
        } else {
            // A row at the top.
            for (areas[i..j], out[i..j]) |area, *o| {
                const length = if (thickness > 0) area / thickness else 0;
                o.* = .{ .x = r.x + along, .y = r.y, .w = length, .h = thickness };
                along += length;
            }
            r.y += thickness;
            r.h = @max(r.h - thickness, 0);
        }
        i = j;
    }
}

/// The worst aspect ratio of a row of tiles from `largest` to `smallest`
/// summing to `sum`, laid along `side`.
fn worstRatio(largest: f32, smallest: f32, sum: f32, side: f32) f32 {
    const s2 = sum * sum;
    const w2 = side * side;
    return @max(w2 * largest / s2, s2 / (w2 * @max(smallest, 1e-9)));
}

// ---- Tests ----

const testing = std.testing;

/// A tree by hand: (parent, name, kind, size) in breadth-first order.
fn makeTree(a: Allocator, entries: []const struct { u32, []const u8, scan.Kind, u64 }) !scan.Tree {
    var tree: scan.Tree = .{ .root = try a.dupeSentinel(u8, "root", 0) };
    errdefer tree.deinit(a);
    try tree.names.appendSlice(a, "root");
    try tree.nodes.append(a, .{ .parent = 0, .name_start = 0, .name_len = 4, .kind = .directory, .size = 0, .files = 0 });
    for (entries, 0..) |e, i| {
        const index: u32 = @intCast(i + 1);
        const start: u32 = @intCast(tree.names.items.len);
        try tree.names.appendSlice(a, e[1]);
        try tree.nodes.append(a, .{ .parent = e[0], .name_start = start, .name_len = @intCast(e[1].len), .kind = e[2], .size = e[3], .files = @intFromBool(e[2] == .file) });
        const parent = &tree.nodes.items[e[0]];
        if (parent.child_count == 0) parent.first_child = index;
        parent.child_count += 1;
    }
    var i = tree.nodes.items.len;
    while (i > 1) {
        i -= 1;
        tree.nodes.items[tree.nodes.items[i].parent].size += tree.nodes.items[i].size;
    }
    return tree;
}

test "squarify fills the rectangle" {
    const unit = 400.0 / 24.0;
    const areas = [_]f32{ 6 * unit, 6 * unit, 4 * unit, 3 * unit, 2 * unit, 2 * unit, 1 * unit };
    var out: [areas.len]Rect = undefined;
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    squarify(&areas, bounds, &out);
    var total: f32 = 0;
    for (out, areas) |r, area| {
        try testing.expectApproxEqRel(area, r.w * r.h, 0.001);
        try testing.expect(r.x >= -0.001 and r.y >= -0.001 and r.x + r.w <= 20.001 and r.y + r.h <= 20.001);
        total += r.w * r.h;
    }
    try testing.expectApproxEqRel(@as(f32, 400), total, 0.001);
}

test "a nested layout: frames, tiles, the rest, labels, hits" {
    const a = testing.allocator;
    // root: big/ (with two files), medium.bin, and 200 tiny files.
    var entries: std.ArrayList(struct { u32, []const u8, scan.Kind, u64 }) = .empty;
    defer entries.deinit(a);
    try entries.append(a, .{ 0, "big", .directory, 0 });
    try entries.append(a, .{ 0, "medium.bin", .file, 300_000 });
    for (0..200) |_| try entries.append(a, .{ 0, "tiny.txt", .file, 10 });
    try entries.append(a, .{ 1, "a.zig", .file, 400_000 });
    try entries.append(a, .{ 1, "b.png", .file, 300_000 });
    var tree = try makeTree(a, entries.items);
    defer tree.deinit(a);

    var result = try layout(a, &tree, 0, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .{});
    defer result.deinit(a);

    var folders: usize = 0;
    var files: usize = 0;
    var rests: usize = 0;
    for (result.items.items) |item| switch (item.shape) {
        .folder => folders += 1,
        .file => files += 1,
        .rest => rests += 1,
        .closed => {},
    };
    try testing.expectEqual(@as(usize, 1), folders);
    try testing.expectEqual(@as(usize, 3), files);
    try testing.expectEqual(@as(usize, 1), rests);
    // The rest holds the 200 tiny files.
    for (result.items.items) |item| if (item.shape == .rest) {
        try testing.expectEqual(@as(u32, 200), item.count);
        try testing.expectEqual(@as(u64, 2000), item.size);
    };
    // big/ has a header label; a.zig is code, drawn inside big/.
    const big = result.find(1).?;
    const zig = result.find(203).?;
    try testing.expect(big.contains(zig.x + 1, zig.y + 1));
    try testing.expect(zig.y >= big.y + 18);
    var labelled = false;
    for (result.labels.items) |l| if (l.node == 1 and l.shape == .folder) {
        labelled = true;
        try testing.expectEqualStrings("big", l.name);
    };
    try testing.expect(labelled);
    // A hit inside a.zig finds a.zig (the deepest), not big/.
    const hit = result.hit(zig.x + zig.w / 2, zig.y + zig.h / 2).?;
    try testing.expectEqual(@as(u32, 203), result.items.items[hit].node);
    try testing.expectEqual(categories.Category.code, result.items.items[hit].category);
}
