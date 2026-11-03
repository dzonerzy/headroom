//! Duplicates: files with the same bytes, found among a scan's files of a
//! megabyte and up. Same-size files are compared by a hash of their first
//! and last 64 KiB, and only those still alike are read whole (SHA-256).
//! Hard links (one file, several names) are one file, not duplicates: their
//! space is taken once.

const std = @import("std");
const scan = @import("scan.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Group = struct {
    /// Each copy's size.
    size: u64,
    /// The copies (tree nodes), at least two.
    nodes: []const u32,
};

/// (Its own name: the page's bindings name types by it, and the scan has a
/// Progress.)
pub const DupesProgress = struct {
    /// Files compared, of `files` that might have a twin.
    done: u64,
    files: u64,
    /// Bytes read so far.
    bytes: u64,
};

pub const Report = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, progress: DupesProgress) void,
};

pub const Options = struct {
    min_size: u64 = 1 << 20,
    report: ?Report = null,
    report_ms: u32 = 200,
    cancel: ?*const std.atomic.Value(bool) = null,
    threads: usize = 0,
};

pub const Error = error{ Canceled, OutOfMemory };

/// The groups of identical files under `root`, most space wasted first.
/// `a` must be thread-safe (the threads allocate with it); the result is the
/// caller's (free each group's nodes, then the slice).
pub fn find(a: Allocator, io: Io, tree: *const scan.Tree, root: u32, options: Options) Error![]Group {
    // Files that are big enough, by size.
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(a);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    try stack.append(a, root);
    while (stack.pop()) |dir| {
        const node = tree.node(dir);
        for (0..node.child_count) |i| {
            const child = node.first_child + @as(u32, @intCast(i));
            const c = tree.node(child);
            switch (c.kind) {
                .directory => try stack.append(a, child),
                .file => if (c.size >= options.min_size) try candidates.append(a, child),
                else => {},
            }
        }
    }
    std.mem.sort(u32, candidates.items, tree, struct {
        fn smaller(t: *const scan.Tree, x: u32, y: u32) bool {
            return t.node(x).size < t.node(y).size;
        }
    }.smaller);
    // Runs of the same size: what may have a twin.
    var buckets: std.ArrayList([]const u32) = .empty;
    defer buckets.deinit(a);
    var files: u64 = 0;
    var i: usize = 0;
    while (i < candidates.items.len) {
        var j = i + 1;
        while (j < candidates.items.len and tree.node(candidates.items[j]).size == tree.node(candidates.items[i]).size) j += 1;
        if (j - i >= 2) {
            try buckets.append(a, candidates.items[i..j]);
            files += j - i;
        }
        i = j;
    }

    var work: Work = .{ .a = a, .io = io, .tree = tree, .buckets = buckets.items, .files = files, .cancel = options.cancel };
    defer work.deinit();
    const count = if (options.threads != 0) options.threads else std.math.clamp(std.Thread.getCpuCount() catch 4, 2, 8);
    var threads: [16]std.Thread = undefined;
    var started: usize = 0;
    while (started < @min(count, threads.len)) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, Work.run, .{&work}) catch break;
    }
    if (started == 0) work.run();
    var waited: u32 = 0;
    while (work.finished.load(.acquire) < started) {
        Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
        waited += 20;
        if (waited >= options.report_ms) {
            waited = 0;
            if (options.report) |r| r.call(r.context, work.progress());
        }
    }
    for (threads[0..started]) |t| t.join();
    if (options.report) |r| r.call(r.context, work.progress());
    if (work.failed) return error.OutOfMemory;
    if (canceled(options.cancel)) return error.Canceled;

    const result = try work.groups.toOwnedSlice(a);
    std.mem.sort(Group, result, {}, struct {
        fn wasteful(_: void, x: Group, y: Group) bool {
            return x.size * (x.nodes.len - 1) > y.size * (y.nodes.len - 1);
        }
    }.wasteful);
    return result;
}

pub fn free(a: Allocator, groups: []const Group) void {
    for (groups) |g| a.free(g.nodes);
    a.free(groups);
}

fn canceled(cancel: ?*const std.atomic.Value(bool)) bool {
    return if (cancel) |c| c.load(.monotonic) else false;
}

const Work = struct {
    a: Allocator,
    io: Io,
    tree: *const scan.Tree,
    buckets: []const []const u32,
    files: u64,
    cancel: ?*const std.atomic.Value(bool),
    next: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(usize) = .init(0),
    lock: Io.Mutex = .init,
    groups: std.ArrayList(Group) = .empty,
    failed: bool = false,

    fn deinit(w: *Work) void {
        for (w.groups.items) |g| w.a.free(g.nodes);
        w.groups.deinit(w.a);
    }

    fn progress(w: *Work) DupesProgress {
        return .{ .done = w.done.load(.monotonic), .files = w.files, .bytes = w.bytes.load(.monotonic) };
    }

    fn run(w: *Work) void {
        defer _ = w.finished.fetchAdd(1, .release);
        const buffer = w.a.alloc(u8, 1 << 20) catch {
            w.failed = true;
            return;
        };
        defer w.a.free(buffer);
        while (!canceled(w.cancel)) {
            const index = w.next.fetchAdd(1, .monotonic);
            if (index >= w.buckets.len) return;
            w.bucket(w.buckets[index], buffer) catch {
                w.failed = true;
                return;
            };
        }
    }

    const Seen = struct { node: u32, inode: u64, quick: u64, digest: [32]u8 = undefined };

    /// One run of same-size files: its groups of identical ones.
    fn bucket(w: *Work, nodes: []const u32, buffer: []u8) Allocator.Error!void {
        var arena: std.heap.ArenaAllocator = .init(w.a);
        defer arena.deinit();
        const a = arena.allocator();
        var seen: std.ArrayList(Seen) = .empty;
        // Each file's identity and its ends' hash; hard links once.
        for (nodes) |node| {
            defer _ = w.done.fetchAdd(1, .monotonic);
            const path = w.tree.path(a, node) catch continue;
            var file = Io.Dir.cwd().openFile(w.io, path, .{}) catch continue;
            defer file.close(w.io);
            const st = file.stat(w.io) catch continue;
            const inode: u64 = @intCast(st.inode);
            const linked = for (seen.items) |s| {
                if (s.inode == inode and inode != 0) break true;
            } else false;
            if (linked) continue;
            const quick = ends(w, file, st.size, buffer) orelse continue;
            try seen.append(a, .{ .node = node, .inode = inode, .quick = quick });
        }
        // Those whose ends are alike, read whole.
        std.mem.sort(Seen, seen.items, {}, struct {
            fn by(_: void, x: Seen, y: Seen) bool {
                return x.quick < y.quick;
            }
        }.by);
        var alike: std.ArrayList(Seen) = .empty;
        var i: usize = 0;
        while (i < seen.items.len) {
            var j = i + 1;
            while (j < seen.items.len and seen.items[j].quick == seen.items[i].quick) j += 1;
            if (j - i >= 2) for (seen.items[i..j]) |s| {
                var whole = s;
                if (w.digest(s.node, a, buffer, &whole.digest)) try alike.append(a, whole);
            };
            i = j;
        }
        std.mem.sort(Seen, alike.items, {}, struct {
            fn by(_: void, x: Seen, y: Seen) bool {
                return std.mem.order(u8, &x.digest, &y.digest) == .lt;
            }
        }.by);
        i = 0;
        while (i < alike.items.len) {
            var j = i + 1;
            while (j < alike.items.len and std.mem.eql(u8, &alike.items[j].digest, &alike.items[i].digest)) j += 1;
            if (j - i >= 2) {
                const copies = try w.a.alloc(u32, j - i);
                for (alike.items[i..j], copies) |s, *c| c.* = s.node;
                w.lock.lockUncancelable(w.io);
                defer w.lock.unlock(w.io);
                w.groups.append(w.a, .{ .size = w.tree.node(copies[0]).size, .nodes = copies }) catch {
                    w.a.free(copies);
                    return error.OutOfMemory;
                };
            }
            i = j;
        }
    }

    /// A hash of the file's length, first and last 64 KiB.
    fn ends(w: *Work, file: Io.File, length: u64, buffer: []u8) ?u64 {
        var hash = std.hash.Wyhash.init(length);
        const edge: usize = 64 * 1024;
        const head = file.readPositionalAll(w.io, buffer[0..@min(edge, length)], 0) catch return null;
        hash.update(buffer[0..head]);
        if (length > 2 * edge) {
            const tail = file.readPositionalAll(w.io, buffer[0..edge], length - edge) catch return null;
            hash.update(buffer[0..tail]);
        }
        _ = w.bytes.fetchAdd(head + if (length > 2 * edge) edge else 0, .monotonic);
        return hash.final();
    }

    /// The whole file's SHA-256; false if it could not be read.
    fn digest(w: *Work, node: u32, a: Allocator, buffer: []u8, out: *[32]u8) bool {
        const path = w.tree.path(a, node) catch return false;
        var file = Io.Dir.cwd().openFile(w.io, path, .{}) catch return false;
        defer file.close(w.io);
        var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
        var offset: u64 = 0;
        while (true) {
            if (canceled(w.cancel)) return false;
            const n = file.readPositionalAll(w.io, buffer, offset) catch return false;
            if (n == 0) break;
            sha.update(buffer[0..n]);
            offset += n;
            _ = w.bytes.fetchAdd(n, .monotonic);
            if (n < buffer.len) break;
        }
        sha.final(out);
        return true;
    }
};

// ---- Tests: real files ----

const testing = std.testing;

fn writeBytes(dir: Io.Dir, path: []const u8, size: usize, seed: u8) !void {
    const io = testing.io;
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, k| b.* = @truncate(k *% 31 +% seed);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "the same bytes found, a same-size file with other bytes not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const mb = 1 << 20;
    try writeBytes(tmp.dir, "a/movie.mkv", 3 * mb, 7);
    try writeBytes(tmp.dir, "b/movie copy.mkv", 3 * mb, 7);
    try writeBytes(tmp.dir, "c/other.mkv", 3 * mb, 9); // same size, other bytes
    try writeBytes(tmp.dir, "d/small.txt", 1000, 7); // under the minimum
    try writeBytes(tmp.dir, "d/small copy.txt", 1000, 7);
    // The same ends, another middle: read whole, not a duplicate.
    try writeBytes(tmp.dir, "e/edited.mkv", 3 * mb, 7);
    {
        var file = try tmp.dir.openFile(io, "e/edited.mkv", .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, "changed", mb + 17);
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var tree = try scan.scan(testing.allocator, io, root, .{});
    defer tree.deinit(testing.allocator);

    const groups = try find(testing.allocator, io, &tree, 0, .{ .threads = 2 });
    defer free(testing.allocator, groups);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(@as(usize, 2), groups[0].nodes.len);
    var names: [2][]const u8 = undefined;
    for (groups[0].nodes, &names) |n, *name| name.* = tree.name(n);
    std.mem.sort([]const u8, &names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    try testing.expectEqualStrings("movie copy.mkv", names[0]);
    try testing.expectEqualStrings("movie.mkv", names[1]);
}

test "canceled" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeBytes(tmp.dir, "x.bin", 2 << 20, 1);
    try writeBytes(tmp.dir, "y.bin", 2 << 20, 1);
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var tree = try scan.scan(testing.allocator, io, root, .{});
    defer tree.deinit(testing.allocator);
    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Canceled, find(testing.allocator, io, &tree, 0, .{ .cancel = &cancel }));
}
