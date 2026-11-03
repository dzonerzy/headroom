//! The scanner: everything under a folder and what each entry takes on the
//! disk, read by several threads at once. Plume-free: the tests use it as it
//! is.
//!
//! Sizes are allocated bytes, not lengths: what fills a disk. Links and
//! junctions are not followed and other filesystems mounted inside are not
//! entered. On Linux a file with several hard links counts once; on Windows
//! each of its links counts (telling them apart would mean opening every file).
//!
//! The tree is one array: a directory's children are side by side
//! (`first_child`, `child_count`) and always after it, so totals are summed in
//! one pass from the end.

const std = @import("std");
const builtin = @import("builtin");
const ntfs = @import("ntfs.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) {
    file,
    directory,
    /// A symbolic link or a junction: not followed.
    link,
    /// Another filesystem mounted here: not entered.
    mount,
    /// A device, a pipe, a socket.
    other,
};

pub const Node = struct {
    parent: u32,
    first_child: u32 = 0,
    child_count: u32 = 0,
    name_start: u32,
    name_len: u32,
    kind: Kind,
    /// A directory that could not be read (permissions, removed meanwhile):
    /// what it holds is not counted.
    unreadable: bool = false,
    /// Bytes on the disk, everything under it included.
    size: u64,
    /// Files under it; 1 for a file.
    files: u64,
    /// When it was last written, seconds since 1970 (its own: a folder's is
    /// when its entries last changed); 0 when unknown.
    mtime: i64 = 0,
};

/// A Windows FILETIME (100 ns since 1601) as seconds since 1970.
pub fn unixSeconds(filetime: i64) i64 {
    return if (filetime <= 0) 0 else @divFloor(filetime, 10_000_000) - 11_644_473_600;
}

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// The folder scanned, absolute; also the root node's name.
    root: [:0]const u8,
    /// Directories that could not be read.
    unreadable: u64 = 0,
    /// Read from an NTFS volume's file table (administrator, Windows):
    /// hard links counted once, nothing unreadable.
    from_mft: bool = false,

    pub const root_index: u32 = 0;

    pub fn deinit(tree: *Tree, a: Allocator) void {
        tree.nodes.deinit(a);
        tree.names.deinit(a);
        a.free(tree.root);
        tree.* = undefined;
    }

    pub fn node(tree: *const Tree, index: u32) Node {
        return tree.nodes.items[index];
    }

    pub fn name(tree: *const Tree, index: u32) []const u8 {
        const n = tree.nodes.items[index];
        return tree.names.items[n.name_start..][0..n.name_len];
    }

    /// The children of `index`: their indices are `first_child + i`.
    pub fn children(tree: *const Tree, index: u32) []const Node {
        const n = tree.nodes.items[index];
        return tree.nodes.items[n.first_child..][0..n.child_count];
    }

    /// The absolute path of `index`.
    pub fn path(tree: *const Tree, a: Allocator, index: u32) ![]u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(a);
        var at = index;
        while (at != root_index) : (at = tree.nodes.items[at].parent) try parts.append(a, tree.name(at));
        try parts.append(a, tree.root);
        std.mem.reverse([]const u8, parts.items);
        return std.fs.path.join(a, parts.items);
    }
};

pub const Progress = struct {
    files: u64 = 0,
    directories: u64 = 0,
    bytes: u64 = 0,
    unreadable: u64 = 0,
};

pub const Report = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, progress: Progress) void,
};

pub const Options = struct {
    /// Threads reading directories; 0: one per CPU, at least 2 and at most 16
    /// (the work is waiting on the disk more than computing).
    threads: usize = 0,
    /// Called about every `report_ms` while the scan runs, and once at its
    /// end, on the thread that called `scan`.
    report: ?Report = null,
    report_ms: u32 = 100,
    /// Set from any thread: the scan stops and returns error.Canceled.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Windows: read the volume's file table when it can (as administrator,
    /// on NTFS), folder by folder otherwise.
    mft: bool = true,
};

pub const Error = error{ Canceled, NotDir, FileNotFound, AccessDenied } || Allocator.Error;

/// Everything under `path`. `a` must be thread-safe (std.heap.smp_allocator,
/// std.testing.allocator): the threads allocate with it.
pub fn scan(a: Allocator, io: Io, path: []const u8, options: Options) Error!Tree {
    const root = Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.AccessDenied,
        else => error.FileNotFound,
    };
    {
        var dir = Io.Dir.openDirAbsolute(io, root, .{}) catch |err| {
            a.free(root);
            return switch (err) {
                error.NotDir => error.NotDir,
                error.AccessDenied => error.AccessDenied,
                else => error.FileNotFound,
            };
        };
        dir.close(io);
    }
    // The volume's file table, when Windows lets it be read (administrator,
    // NTFS): one sequential read, hard links once.
    if (builtin.os.tag == .windows and options.mft) {
        if (ntfs.readVolume(a, io, root, .{ .report = options.report, .cancel = options.cancel })) |t| {
            a.free(root);
            var read = t;
            read.from_mft = true;
            if (options.report) |report| report.call(report.context, .{ .files = read.node(0).files, .directories = 0, .bytes = read.node(0).size, .unreadable = 0 });
            return read;
        } else |err| switch (err) {
            error.Canceled => {
                a.free(root);
                return error.Canceled;
            },
            else => {},
        }
    }
    var tree: Tree = .{ .root = root };
    errdefer tree.deinit(a);
    try tree.names.appendSlice(a, root);
    try tree.nodes.append(a, .{ .parent = 0, .name_start = 0, .name_len = @intCast(root.len), .kind = .directory, .size = 0, .files = 0 });

    var s: Scan = .{ .a = a, .io = io, .tree = &tree, .cancel = options.cancel };
    defer s.deinit();
    if (builtin.os.tag == .linux) {
        s.root_device = device(statx(std.os.linux.AT.FDCWD, root) orelse return error.FileNotFound);
    }
    try s.queue.append(a, .{ .index = Tree.root_index, .path = try a.dupeSentinel(u8, root, 0) });

    const count = if (options.threads != 0) options.threads else std.math.clamp(std.Thread.getCpuCount() catch 4, 2, 16);
    var threads: [64]std.Thread = undefined;
    var started: usize = 0;
    while (started < @min(count, threads.len)) : (started += 1) {
        threads[started] = std.Thread.spawn(.{}, Scan.work, .{&s}) catch break;
    }
    if (started == 0) s.work();

    var waited: u32 = 0;
    while (!s.finished()) {
        Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        waited += 10;
        if (waited >= options.report_ms) {
            waited = 0;
            if (options.report) |report| report.call(report.context, s.progress());
        }
    }
    for (threads[0..started]) |thread| thread.join();

    if (s.failure) |err| return err;
    if (s.canceled()) return error.Canceled;

    // Totals: children are after their parent, so one pass from the end.
    const nodes = tree.nodes.items;
    var i = nodes.len;
    while (i > 1) {
        i -= 1;
        nodes[nodes[i].parent].size += nodes[i].size;
        nodes[nodes[i].parent].files += nodes[i].files;
    }
    tree.unreadable = s.unreadable.load(.monotonic);
    if (options.report) |report| report.call(report.context, s.progress());
    return tree;
}

const Job = struct { index: u32, path: [:0]u8 };

/// A directory's entry as read, before it is in the tree.
const Entry = struct { name_start: u32, name_len: u32, kind: Kind, size: u64, mtime: i64 };

const Scan = struct {
    a: Allocator,
    io: Io,
    tree: *Tree,
    cancel: ?*const std.atomic.Value(bool),
    root_device: u64 = 0,

    tree_lock: Io.Mutex = .init,

    queue: std.ArrayList(Job) = .empty,
    queue_lock: Io.Mutex = .init,
    queue_ready: Io.Condition = .init,
    /// Workers with a job (queue_lock).
    busy: usize = 0,
    done: bool = false,
    failure: ?Error = null,

    /// (device, inode) of the files with several links seen (Linux).
    links: std.AutoHashMapUnmanaged([2]u64, void) = .empty,
    links_lock: Io.Mutex = .init,

    files: std.atomic.Value(u64) = .init(0),
    directories: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    unreadable: std.atomic.Value(u64) = .init(0),

    fn deinit(s: *Scan) void {
        for (s.queue.items) |job| s.a.free(job.path);
        s.queue.deinit(s.a);
        s.links.deinit(s.a);
    }

    fn progress(s: *Scan) Progress {
        return .{
            .files = s.files.load(.monotonic),
            .directories = s.directories.load(.monotonic),
            .bytes = s.bytes.load(.monotonic),
            .unreadable = s.unreadable.load(.monotonic),
        };
    }

    fn canceled(s: *Scan) bool {
        return if (s.cancel) |flag| flag.load(.monotonic) else false;
    }

    fn finished(s: *Scan) bool {
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        return s.done;
    }

    fn work(s: *Scan) void {
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(s.a);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(s.a);
        var jobs: std.ArrayList(Job) = .empty;
        defer jobs.deinit(s.a);
        const buffer = s.a.alignedAlloc(u8, .@"8", 64 * 1024) catch return s.fail(error.OutOfMemory);
        defer s.a.free(buffer);

        while (s.next()) |job| {
            s.read(job, &entries, &names, &jobs, buffer) catch |err| s.fail(err);
            s.a.free(job.path);
            s.queue_lock.lockUncancelable(s.io);
            defer s.queue_lock.unlock(s.io);
            s.busy -= 1;
            if (s.queue.items.len == 0 and s.busy == 0) {
                s.done = true;
                s.queue_ready.broadcast(s.io);
            }
        }
    }

    /// The next directory to read, or null once there is none left.
    fn next(s: *Scan) ?Job {
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        while (true) {
            if (!s.done and s.canceled()) {
                s.done = true;
                s.queue_ready.broadcast(s.io);
            }
            if (s.done) return null;
            if (s.queue.pop()) |job| {
                s.busy += 1;
                return job;
            }
            s.queue_ready.waitUncancelable(s.io, &s.queue_lock);
        }
    }

    fn fail(s: *Scan, err: Error) void {
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        if (s.failure == null) s.failure = err;
        s.done = true;
        s.queue_ready.broadcast(s.io);
    }

    /// One directory: its entries into the tree, its subdirectories queued.
    fn read(s: *Scan, job: Job, entries: *std.ArrayList(Entry), names: *std.ArrayList(u8), jobs: *std.ArrayList(Job), buffer: []align(8) u8) Error!void {
        entries.clearRetainingCapacity();
        names.clearRetainingCapacity();
        jobs.clearRetainingCapacity();
        _ = s.directories.fetchAdd(1, .monotonic);

        const listed = listed: {
            var dir = Io.Dir.openDirAbsolute(s.io, job.path, .{ .iterate = true, .follow_symlinks = false }) catch break :listed false;
            defer dir.close(s.io);
            const list = if (builtin.os.tag == .windows) listWindows else listPosix;
            list(s, dir, entries, names, buffer) catch |err| switch (err) {
                error.Unreadable => break :listed false,
                error.OutOfMemory => return error.OutOfMemory,
            };
            break :listed true;
        };

        var files: u64 = 0;
        var bytes: u64 = 0;
        // Where the entries go in the tree: taken under the lock, as other
        // threads append theirs.
        var first: u32 = 0;
        {
            s.tree_lock.lockUncancelable(s.io);
            defer s.tree_lock.unlock(s.io);
            const tree = s.tree;
            if (!listed) {
                tree.nodes.items[job.index].unreadable = true;
                _ = s.unreadable.fetchAdd(1, .monotonic);
                return;
            }
            first = @intCast(tree.nodes.items.len);
            const name_base: u32 = @intCast(tree.names.items.len);
            try tree.nodes.ensureUnusedCapacity(s.a, entries.items.len);
            try tree.names.appendSlice(s.a, names.items);
            for (entries.items) |entry| {
                const file = entry.kind == .file;
                if (file) files += 1;
                bytes += entry.size;
                tree.nodes.appendAssumeCapacity(.{
                    .parent = job.index,
                    .name_start = name_base + entry.name_start,
                    .name_len = entry.name_len,
                    .kind = entry.kind,
                    .size = entry.size,
                    .files = @intFromBool(file),
                    .mtime = entry.mtime,
                });
            }
            tree.nodes.items[job.index].first_child = first;
            tree.nodes.items[job.index].child_count = @intCast(entries.items.len);
        }
        _ = s.files.fetchAdd(files, .monotonic);
        _ = s.bytes.fetchAdd(bytes, .monotonic);

        for (entries.items, 0..) |entry, i| {
            if (entry.kind != .directory) continue;
            const child_name = names.items[entry.name_start..][0..entry.name_len];
            const child_path = try std.fs.path.joinZ(s.a, &.{ job.path, child_name });
            jobs.append(s.a, .{ .index = first + @as(u32, @intCast(i)), .path = child_path }) catch {
                s.a.free(child_path);
                return error.OutOfMemory;
            };
        }
        if (jobs.items.len == 0) return;
        s.queue_lock.lockUncancelable(s.io);
        defer s.queue_lock.unlock(s.io);
        s.queue.appendSlice(s.a, jobs.items) catch {
            for (jobs.items) |child| s.a.free(child.path);
            return error.OutOfMemory;
        };
        s.queue_ready.broadcast(s.io);
    }

    /// Whether this is the first of a hard-linked file's links seen.
    fn firstLink(s: *Scan, dev: u64, inode: u64) Allocator.Error!bool {
        s.links_lock.lockUncancelable(s.io);
        defer s.links_lock.unlock(s.io);
        const entry = try s.links.getOrPut(s.a, .{ dev, inode });
        return !entry.found_existing;
    }
};

const ListError = error{Unreadable} || Allocator.Error;

/// Windows: NtQueryDirectoryFile gives each entry's allocation with its name,
/// so nothing is opened or queried per file.
fn listWindows(s: *Scan, dir: Io.Dir, entries: *std.ArrayList(Entry), names: *std.ArrayList(u8), buffer: []align(8) u8) ListError!void {
    const w = std.os.windows;
    var restart = true;
    while (true) {
        var status: w.IO_STATUS_BLOCK = undefined;
        const rc = w.ntdll.NtQueryDirectoryFile(dir.handle, null, null, null, &status, buffer.ptr, @intCast(buffer.len), .BothDirectory, .FALSE, null, .fromBool(restart));
        restart = false;
        switch (rc) {
            .SUCCESS => {},
            .NO_MORE_FILES => return,
            else => return error.Unreadable,
        }
        if (status.Information == 0) return;
        var offset: usize = 0;
        while (true) {
            const info: *align(2) const w.FILE_BOTH_DIR_INFORMATION = @ptrCast(@alignCast(&buffer[offset]));
            const wide = @as([*]align(2) const u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
            if (!dots(u16, wide)) {
                const attributes = info.FileAttributes;
                // A directory that is a reparse point is a junction, a link
                // or a mount: not entered. A file one (OneDrive's, a dedup
                // chunk) is a file, its allocation what is really there.
                const kind: Kind = if (!attributes.DIRECTORY) .file else if (attributes.REPARSE_POINT) .link else .directory;
                const start = names.items.len;
                try names.ensureUnusedCapacity(s.a, wide.len * 3);
                names.items.len += std.unicode.wtf16LeToWtf8(names.unusedCapacitySlice(), wide);
                try entries.append(s.a, .{
                    .name_start = @intCast(start),
                    .name_len = @intCast(names.items.len - start),
                    .kind = kind,
                    .size = if (kind == .link) 0 else @intCast(@max(info.AllocationSize, 0)),
                    .mtime = unixSeconds(info.LastWriteTime),
                });
            }
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }
}

/// Linux: the names from the directory, each entry's allocation from statx.
fn listPosix(s: *Scan, dir: Io.Dir, entries: *std.ArrayList(Entry), names: *std.ArrayList(u8), buffer: []align(8) u8) ListError!void {
    _ = buffer;
    if (builtin.os.tag != .linux) @compileError("the scanner reads Windows and Linux");
    const linux = std.os.linux;
    var it = dir.iterate();
    while (it.next(s.io) catch return error.Unreadable) |entry| {
        const start = names.items.len;
        try names.ensureUnusedCapacity(s.a, entry.name.len + 1);
        names.appendSliceAssumeCapacity(entry.name);
        names.appendAssumeCapacity(0);
        const st = statx(dir.handle, names.items[start .. names.items.len - 1 :0]);
        names.items.len -= 1;
        // Removed since the directory was read.
        const found = st orelse {
            names.items.len = start;
            continue;
        };
        const kind: Kind = switch (found.mode & linux.S.IFMT) {
            linux.S.IFREG => .file,
            linux.S.IFDIR => if (device(found) == s.root_device) .directory else .mount,
            linux.S.IFLNK => .link,
            else => .other,
        };
        var size: u64 = if (kind == .mount) 0 else found.blocks * 512;
        if (kind == .file and found.nlink > 1 and !try s.firstLink(device(found), found.ino)) size = 0;
        try entries.append(s.a, .{ .name_start = @intCast(start), .name_len = @intCast(entry.name.len), .kind = kind, .size = size, .mtime = found.mtime.sec });
    }
}

fn statx(dir: std.posix.fd_t, path: [:0]const u8) ?std.os.linux.Statx {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    const rc = linux.statx(dir, path.ptr, linux.AT.SYMLINK_NOFOLLOW | linux.AT.STATX_DONT_SYNC, .{ .TYPE = true, .NLINK = true, .INO = true, .BLOCKS = true, .MTIME = true }, &st);
    return if (linux.errno(rc) == .SUCCESS) st else null;
}

fn device(st: std.os.linux.Statx) u64 {
    return @as(u64, st.dev_major) << 32 | st.dev_minor;
}

fn dots(comptime T: type, name: []const T) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

// Tests: a small tree made in a temporary folder, scanned.

const testing = std.testing;

fn write(dir: Io.Dir, io: Io, path: []const u8, bytes: usize) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const data = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn find(tree: *const Tree, parent: u32, name: []const u8) ?u32 {
    const first = tree.node(parent).first_child;
    for (tree.children(parent), 0..) |_, i| {
        const index: u32 = @intCast(first + i);
        if (std.mem.eql(u8, tree.name(index), name)) return index;
    }
    return null;
}

test "a tree, its totals and paths" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, io, "a/one.bin", 100_000);
    try write(tmp.dir, io, "a/b/two.bin", 300_000);
    try write(tmp.dir, io, "a/b/c/three.bin", 10);
    try write(tmp.dir, io, "four.bin", 50_000);
    try tmp.dir.createDirPath(io, "empty");

    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var reports: usize = 0;
    const Count = struct {
        fn call(context: *anyopaque, _: Progress) void {
            const count: *usize = @ptrCast(@alignCast(context));
            count.* += 1;
        }
    };
    var tree = try scan(testing.allocator, io, root, .{ .threads = 3, .report = .{ .context = &reports, .call = Count.call } });
    defer tree.deinit(testing.allocator);

    try testing.expect(reports >= 1);
    try testing.expectEqualStrings(root, tree.root);
    const top = tree.node(Tree.root_index);
    try testing.expectEqual(@as(u64, 4), top.files);
    try testing.expectEqual(@as(u32, 3), top.child_count);
    // Allocated: at least each file's length (a 10-byte file may be stored
    // inside the file table on NTFS: 0 then).
    try testing.expect(top.size >= 450_000);

    const a = find(&tree, Tree.root_index, "a").?;
    const b = find(&tree, a, "b").?;
    const c = find(&tree, b, "c").?;
    const empty = find(&tree, Tree.root_index, "empty").?;
    try testing.expectEqual(Kind.directory, tree.node(a).kind);
    try testing.expectEqual(@as(u64, 3), tree.node(a).files);
    try testing.expectEqual(@as(u64, 2), tree.node(b).files);
    try testing.expect(tree.node(b).size >= 300_000);
    try testing.expect(tree.node(a).size >= tree.node(b).size + 100_000);
    try testing.expectEqual(@as(u64, 0), tree.node(empty).files);
    try testing.expectEqual(@as(u32, 0), tree.node(empty).child_count);

    const three = find(&tree, c, "three.bin").?;
    const path = try tree.path(testing.allocator, three);
    defer testing.allocator.free(path);
    const expected = try std.fs.path.join(testing.allocator, &.{ root, "a", "b", "c", "three.bin" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, path);
    // Every directory's size is its children's (and, on Linux, its own blocks).
    for (tree.nodes.items, 0..) |n, i| {
        if (n.kind != .directory) continue;
        var sum: u64 = 0;
        for (tree.children(@intCast(i))) |child| sum += child.size;
        try testing.expect(n.size >= sum);
    }
}

test "names beyond ASCII" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, io, "Fotografía/日本.jpg", 5_000);
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var tree = try scan(testing.allocator, io, root, .{});
    defer tree.deinit(testing.allocator);
    const folder = find(&tree, Tree.root_index, "Fotografía").?;
    try testing.expect(find(&tree, folder, "日本.jpg") != null);
}

/// Sets `path`'s modification time (tests: files from a while ago).
pub fn setMtime(dir: Io.Dir, io: Io, path: []const u8, seconds: i64) !void {
    var file = try dir.openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s } } });
}

test "modification times" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, io, "old/notes.md", 1_000);
    try write(tmp.dir, io, "new.md", 1_000);
    // 2024-01-02, and a day later.
    try setMtime(tmp.dir, io, "old/notes.md", 1_704_153_600);
    try setMtime(tmp.dir, io, "new.md", 1_704_240_000);
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var tree = try scan(testing.allocator, io, root, .{});
    defer tree.deinit(testing.allocator);
    const old = find(&tree, Tree.root_index, "old").?;
    try testing.expectEqual(@as(i64, 1_704_153_600), tree.node(find(&tree, old, "notes.md").?).mtime);
    try testing.expectEqual(@as(i64, 1_704_240_000), tree.node(find(&tree, Tree.root_index, "new.md").?).mtime);
    // A folder has its own: when its entries changed (now, roughly).
    try testing.expect(tree.node(old).mtime > 1_704_240_000);
}

test "unixSeconds" {
    try testing.expectEqual(@as(i64, 0), unixSeconds(0));
    // 2024-01-02 00:00 UTC as a FILETIME.
    try testing.expectEqual(@as(i64, 1_704_153_600), unixSeconds(133_486_272_000_000_000));
}

test "canceled" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, io, "a/b/c.bin", 10);
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var cancel: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.Canceled, scan(testing.allocator, io, root, .{ .cancel = &cancel }));
}

test "not a folder" {
    const io = testing.io;
    try testing.expectError(error.FileNotFound, scan(testing.allocator, io, "/no/such/folder/headroom", .{}));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, io, "file.bin", 10);
    const file = try tmp.dir.realPathFileAlloc(io, "file.bin", testing.allocator);
    defer testing.allocator.free(file);
    try testing.expectError(error.NotDir, scan(testing.allocator, io, file, .{}));
}
