//! What grew: after each scan, the sizes of a folder's big folders are kept
//! (a small text file per scanned folder); the next scan of it is compared
//! with them. Changes are told where they happened: a folder whose growth is
//! mostly one of its folders' gives way to it.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
const Allocator = std.mem.Allocator;

/// Kept: folders this big or bigger, this deep or less (the top level always).
pub const keep_from = 32 * 1024 * 1024;
pub const keep_depth = 6;
/// Told: changes this big or bigger.
pub const tell_from = 64 * 1024 * 1024;

pub const Entry = struct { path: []const u8, size: u64 };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    time_ms: i64,
    total: u64,
    entries: []Entry,

    pub fn deinit(s: *Snapshot) void {
        s.arena.deinit();
    }
};

pub const Change = struct {
    /// From the folder scanned, "/" between folders.
    path: []const u8,
    before: u64,
    after: u64,
    /// In the new tree, if it is there.
    node: ?u32,
};

pub const Changes = struct {
    since_ms: i64,
    before: u64,
    after: u64,
    grew: []Change,
    shrank: []Change,
};

/// The file a folder's snapshot is kept in, under `folder`.
pub fn fileFor(a: Allocator, folder: []const u8, root: []const u8) ![]u8 {
    var hasher: std.hash.Wyhash = .init(0);
    for (root) |c| hasher.update(&.{if (builtin.os.tag == .windows) std.ascii.toLower(c) else c});
    var name: [32]u8 = undefined;
    const file = try std.fmt.bufPrint(&name, "{x:0>16}.tsv", .{hasher.final()});
    return std.fs.path.join(a, &.{ folder, file });
}

/// The tree's snapshot, as the file holds it: a header line, then
/// "size<TAB>path" per folder kept.
pub fn take(a: Allocator, tree: *const scan.Tree, time_ms: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("headroom-snapshot 1\t{d}\t{d}\n", .{ time_ms, tree.node(0).size });
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(a);
    try walk(a, tree, 0, 0, &path, w);
    return out.toOwnedSlice();
}

fn walk(a: Allocator, tree: *const scan.Tree, dir: u32, depth: usize, path: *std.ArrayList(u8), w: *std.Io.Writer) !void {
    const node = tree.node(dir);
    for (tree.children(dir), 0..) |child, i| {
        if (child.kind != .directory) continue;
        if (child.size < keep_from and depth > 0) continue;
        const index = node.first_child + @as(u32, @intCast(i));
        const mark = path.items.len;
        if (mark > 0) try path.append(a, '/');
        try path.appendSlice(a, tree.name(index));
        try w.print("{d}\t{s}\n", .{ child.size, path.items });
        if (depth + 1 < keep_depth and child.size >= keep_from) try walk(a, tree, index, depth + 1, path, w);
        path.shrinkRetainingCapacity(mark);
    }
}

pub fn parse(gpa: Allocator, bytes: []const u8) !Snapshot {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = lines.next() orelse return error.Invalid;
    var fields = std.mem.splitScalar(u8, header, '\t');
    if (!std.mem.eql(u8, fields.next() orelse "", "headroom-snapshot 1")) return error.Invalid;
    const time_ms = std.fmt.parseInt(i64, fields.next() orelse "", 10) catch return error.Invalid;
    const total = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch return error.Invalid;
    var entries: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.Invalid;
        const size = std.fmt.parseInt(u64, line[0..tab], 10) catch return error.Invalid;
        try entries.append(a, .{ .path = try a.dupe(u8, line[tab + 1 ..]), .size = size });
    }
    return .{ .arena = arena, .time_ms = time_ms, .total = total, .entries = entries.items };
}

/// What changed from `old` to `tree`, where it happened, biggest first.
pub fn diff(a: Allocator, old: *const Snapshot, tree: *const scan.Tree) !Changes {
    var all: std.ArrayList(Change) = .empty;
    defer all.deinit(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (old.entries) |e| {
        const node = find(tree, e.path);
        const after = if (node) |n| tree.node(n).size else 0;
        try seen.put(a, e.path, {});
        if (absDelta(e.size, after) >= tell_from) try all.append(a, .{ .path = e.path, .before = e.size, .after = after, .node = node });
    }
    // New folders (not in the old snapshot).
    const current = try take(a, tree, 0);
    defer a.free(current);
    var lines = std.mem.splitScalar(u8, current, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = line[tab + 1 ..];
        if (seen.contains(path)) continue;
        const size = std.fmt.parseInt(u64, line[0..tab], 10) catch continue;
        if (size >= tell_from) try all.append(a, .{ .path = try a.dupe(u8, path), .before = 0, .after = size, .node = find(tree, path) });
    }

    // Where it happened: a change mostly explained by one of its folders'
    // is left to that folder.
    var told: std.ArrayList(Change) = .empty;
    errdefer told.deinit(a);
    for (all.items) |c| {
        const delta = signed(c);
        const explained = for (all.items) |d| {
            if (d.path.len <= c.path.len + 1 or !std.mem.startsWith(u8, d.path, c.path) or d.path[c.path.len] != '/') continue;
            const inner = signed(d);
            if ((inner > 0) == (delta > 0) and @abs(inner) * 10 >= @abs(delta) * 7) break true;
        } else false;
        if (!explained) try told.append(a, c);
    }
    var grew: std.ArrayList(Change) = .empty;
    var shrank: std.ArrayList(Change) = .empty;
    for (told.items) |c| try (if (signed(c) > 0) &grew else &shrank).append(a, c);
    told.deinit(a);
    std.mem.sort(Change, grew.items, {}, struct {
        fn more(_: void, l: Change, r: Change) bool {
            return signed(l) > signed(r);
        }
    }.more);
    std.mem.sort(Change, shrank.items, {}, struct {
        fn more(_: void, l: Change, r: Change) bool {
            return signed(l) < signed(r);
        }
    }.more);
    return .{
        .since_ms = old.time_ms,
        .before = old.total,
        .after = tree.node(0).size,
        .grew = try grew.toOwnedSlice(a),
        .shrank = try shrank.toOwnedSlice(a),
    };
}

fn signed(c: Change) i64 {
    return @as(i64, @intCast(c.after)) - @as(i64, @intCast(c.before));
}

fn absDelta(x: u64, y: u64) u64 {
    return if (x > y) x - y else y - x;
}

/// The node at `path` ("a/b/c") from the tree's root.
pub fn find(tree: *const scan.Tree, path: []const u8) ?u32 {
    var at: u32 = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    outer: while (parts.next()) |part| {
        const node = tree.node(at);
        for (tree.children(at), 0..) |_, i| {
            const index = node.first_child + @as(u32, @intCast(i));
            if (std.mem.eql(u8, tree.name(index), part)) {
                at = index;
                continue :outer;
            }
        }
        return null;
    }
    return at;
}

// ---- Tests ----

const testing = std.testing;
const testtree = @import("testtree.zig");
const MB = 1024 * 1024;

test "a snapshot, read back, and what changed where" {
    const a = testing.allocator;
    var before = try testtree.make(a, "/home/ada", &.{
        .{ 0, "projects", .directory, 0 }, // 1
        .{ 0, "photos", .directory, 0 }, // 2
        .{ 0, "tiny", .directory, 0 }, // 3
        .{ 1, "zeroG", .directory, 0 }, // 4
        .{ 1, "old", .directory, 0 }, // 5
        .{ 2, "a.raw", .file, 500 * MB }, // 6
        .{ 3, "x", .file, 1000 }, // 7
        .{ 4, "build", .directory, 0 }, // 8
        .{ 5, "big.iso", .file, 300 * MB }, // 9
        .{ 8, "obj", .file, 200 * MB }, // 10
    });
    defer before.deinit(a);
    const bytes = try take(a, &before, 1_700_000_000_000);
    defer a.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "projects/zeroG/build") != null);
    // The top level is kept however small.
    try testing.expect(std.mem.indexOf(u8, bytes, "\ttiny\n") != null);
    var old = try parse(a, bytes);
    defer old.deinit();
    try testing.expectEqual(@as(i64, 1_700_000_000_000), old.time_ms);

    // Later: build grew by 3 GB, old was deleted, a new downloads folder.
    var after = try testtree.make(a, "/home/ada", &.{
        .{ 0, "projects", .directory, 0 }, // 1
        .{ 0, "photos", .directory, 0 }, // 2
        .{ 0, "downloads", .directory, 0 }, // 3
        .{ 1, "zeroG", .directory, 0 }, // 4
        .{ 2, "a.raw", .file, 500 * MB }, // 5
        .{ 3, "game.zip", .file, 900 * MB }, // 6
        .{ 4, "build", .directory, 0 }, // 7
        .{ 7, "obj", .file, 3200 * MB }, // 8
    });
    defer after.deinit(a);
    const changes = try diff(a, &old, &after);
    defer a.free(changes.grew);
    defer a.free(changes.shrank);
    defer for (changes.grew) |c| if (c.before == 0) a.free(c.path);

    // Told where: build (not zeroG, not projects), downloads; old shrank.
    try testing.expectEqual(@as(usize, 2), changes.grew.len);
    try testing.expectEqualStrings("projects/zeroG/build", changes.grew[0].path);
    try testing.expectEqual(@as(u64, 3200 * MB), changes.grew[0].after);
    try testing.expectEqualStrings("downloads", changes.grew[1].path);
    try testing.expectEqual(@as(usize, 1), changes.shrank.len);
    try testing.expectEqualStrings("projects/old", changes.shrank[0].path);
    try testing.expect(changes.shrank[0].node == null);
}
