//! WSL's Linux distributions, from Windows: which there are and the virtual
//! disk each lives in, what is inside one, and that disk compacted so
//! Windows gets back the space freed inside it.
//!
//! Inside a distribution, its own `find` lists the files (run as root, on its
//! root filesystem only: -xdev keeps /mnt/c and the other mounts out). Read
//! over WSL's file share instead, a distribution of a million files takes
//! minutes and /mnt/c would be the Windows disk again.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Distro = struct {
    name: []const u8,
    /// Its virtual disk (ext4.vhdx).
    disk: []const u8,
    /// What the disk takes on the Windows disk, in bytes.
    size: u64,
    /// 1 or 2: WSL 1 distributions have no virtual disk.
    version: u32,
};

pub const Error = error{ NoWsl, Failed, Canceled, OutOfMemory };

/// The distributions installed for this user (none off Windows). Docker
/// Desktop's own are left out: Docker shows what is in them.
pub fn list(a: Allocator) Error![]Distro {
    if (builtin.os.tag != .windows) return &.{};
    var lxss: HKEY = undefined;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"), 0, KEY_READ, &lxss) != 0) return &.{};
    defer _ = RegCloseKey(lxss);
    var found: std.ArrayList(Distro) = .empty;
    var index: u32 = 0;
    while (true) : (index += 1) {
        var key_name: [128:0]u16 = undefined;
        var key_len: u32 = key_name.len;
        if (RegEnumKeyExW(lxss, index, &key_name, &key_len, null, null, null, null) != 0) break;
        key_name[key_len] = 0;
        const name = try value(a, lxss, &key_name, "DistributionName") orelse continue;
        if (std.mem.startsWith(u8, name, "docker-desktop")) continue;
        const base = try value(a, lxss, &key_name, "BasePath") orelse continue;
        const vhd = try value(a, lxss, &key_name, "VhdFileName") orelse "ext4.vhdx";
        var version: u32 = 0;
        var len: u32 = @sizeOf(u32);
        _ = RegGetValueW(lxss, &key_name, std.unicode.utf8ToUtf16LeStringLiteral("Version"), RRF_RT_REG_DWORD, null, &version, &len);
        const folder = if (std.mem.startsWith(u8, base, "\\\\?\\")) base[4..] else base;
        const disk = try std.fs.path.join(a, &.{ folder, if (vhd.len == 0) "ext4.vhdx" else vhd });
        try found.append(a, .{ .name = name, .disk = disk, .size = diskSize(a, disk), .version = version });
    }
    std.mem.sort(Distro, found.items, {}, struct {
        fn larger(_: void, x: Distro, y: Distro) bool {
            return x.size > y.size;
        }
    }.larger);
    return found.items;
}

/// What `path` takes on the disk (a sparse or compressed file less than
/// its length).
pub fn diskSize(a: Allocator, path: []const u8) u64 {
    if (builtin.os.tag != .windows) return 0;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(a, path) catch return 0;
    defer a.free(wide);
    var high: u32 = 0;
    const low = GetCompressedFileSizeW(wide, &high);
    if (low == 0xFFFF_FFFF and GetLastError() != 0) return 0;
    return @as(u64, high) << 32 | low;
}

/// Everything inside the distribution `name`, as a scan's tree rooted at
/// \\wsl.localhost\<name> (so its paths are deleted through WSL's share).
pub fn scanDistro(a: Allocator, io: Io, name: []const u8, report: ?scan.Report, cancel: ?*const std.atomic.Value(bool)) Error!scan.Tree {
    if (builtin.os.tag != .windows) return error.NoWsl;
    const argv = [_][]const u8{ "wsl.exe", "-d", name, "-u", "root", "--exec", "find", "/", "-xdev", "-printf", "%y %b %i %n %T@ %P\\0" };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore, .create_no_window = true }) catch return error.NoWsl;
    defer child.kill(io);
    var buffer: [64 * 1024]u8 = undefined;
    var stream = child.stdout.?.readerStreaming(io, &buffer);
    const root = try std.fmt.allocPrint(a, "\\\\wsl.localhost\\{s}", .{name});
    defer a.free(root);
    var tree = try build(a, &stream.interface, root, report, cancel);
    errdefer tree.deinit(a);
    const term = child.wait(io) catch return error.Failed;
    // find says 1 when some folder could not be read: the rest is there.
    switch (term) {
        .exited => |code| if (code != 0 and code != 1 or tree.nodes.items.len < 2) return error.Failed,
        else => return error.Failed,
    }
    return tree;
}

/// The tree from find's records ("type blocks inode links mtime path\0",
/// depth first, a folder before what is in it), laid out as the scanner's:
/// a folder's children side by side, after it.
pub fn build(a: Allocator, r: *Io.Reader, root: []const u8, report: ?scan.Report, cancel: ?*const std.atomic.Value(bool)) Error!scan.Tree {
    const Temp = struct { parent: u32, name_start: u32, name_len: u32, kind: scan.Kind, size: u64, mtime: i64, first: u32 = none, next: u32 = none, last: u32 = none };
    var temps: std.ArrayList(Temp) = .empty;
    defer temps.deinit(a);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(a);
    var links: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer links.deinit(a);
    // The folder last seen at each depth: where the next entry goes.
    var folders: std.ArrayList(u32) = .empty;
    defer folders.deinit(a);
    try temps.append(a, .{ .parent = 0, .name_start = 0, .name_len = 0, .kind = .directory, .size = 0, .mtime = 0 });
    try folders.append(a, 0);
    var files: u64 = 0;
    var bytes: u64 = 0;
    var count: u32 = 0;
    while (r.takeDelimiter(0) catch return error.Failed) |record| {
        count +%= 1;
        if (count % 4096 == 0) {
            if (cancel) |c| if (c.load(.monotonic)) return error.Canceled;
            if (report) |rep| rep.call(rep.context, .{ .files = files, .directories = temps.items.len - files, .bytes = bytes });
        }
        var fields = std.mem.splitScalar(u8, record, ' ');
        const kind_text = fields.next() orelse continue;
        const blocks = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const inode = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const nlink = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const mtime_text = fields.next() orelse continue;
        const path = fields.rest();
        const mtime = std.fmt.parseInt(i64, mtime_text[0 .. std.mem.indexOfScalar(u8, mtime_text, '.') orelse mtime_text.len], 10) catch 0;
        const kind: scan.Kind = switch (kind_text[0]) {
            'f' => .file,
            'd' => .directory,
            'l' => .link,
            else => .other,
        };
        if (path.len == 0) {
            // The root itself.
            temps.items[0].mtime = mtime;
            continue;
        }
        const depth = std.mem.count(u8, path, "/") + 1;
        if (depth > folders.items.len) continue; // its folder was not listed
        const parent = folders.items[depth - 1];
        var size = blocks * 512;
        if (kind == .file and nlink > 1) {
            if ((try links.getOrPut(a, inode)).found_existing) size = 0;
        }
        if (kind == .link) size = 0;
        const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse std.math.maxInt(usize)) +% 1 ..];
        const start: u32 = @intCast(names.items.len);
        try appendName(a, &names, base);
        const index: u32 = @intCast(temps.items.len);
        try temps.append(a, .{ .parent = parent, .name_start = start, .name_len = @intCast(names.items.len - start), .kind = kind, .size = size, .mtime = mtime });
        const p = &temps.items[parent];
        if (p.first == none) p.first = index else temps.items[p.last].next = index;
        p.last = index;
        if (kind == .file) files += 1;
        bytes += size;
        if (kind == .directory) {
            folders.shrinkRetainingCapacity(depth);
            try folders.append(a, index);
        }
    }

    // Breadth first into the scanner's layout.
    var tree: scan.Tree = .{ .root = try a.dupeSentinel(u8, root, 0), .linux = true };
    errdefer tree.deinit(a);
    try tree.names.appendSlice(a, root);
    try tree.names.appendSlice(a, names.items);
    const base: u32 = @intCast(root.len);
    try tree.nodes.ensureTotalCapacity(a, temps.items.len);
    tree.nodes.appendAssumeCapacity(.{ .parent = 0, .name_start = 0, .name_len = base, .kind = .directory, .size = 0, .files = 0, .mtime = temps.items[0].mtime });
    var queue: std.ArrayList(struct { temp: u32, node: u32 }) = .empty;
    defer queue.deinit(a);
    try queue.append(a, .{ .temp = 0, .node = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        const first: u32 = @intCast(tree.nodes.items.len);
        var child = temps.items[item.temp].first;
        var children: u32 = 0;
        while (child != none) : (child = temps.items[child].next) {
            const t = temps.items[child];
            const node: u32 = @intCast(tree.nodes.items.len);
            tree.nodes.appendAssumeCapacity(.{ .parent = item.node, .name_start = base + t.name_start, .name_len = t.name_len, .kind = t.kind, .size = t.size, .files = @intFromBool(t.kind == .file), .mtime = t.mtime });
            if (t.kind == .directory) try queue.append(a, .{ .temp = child, .node = node });
            children += 1;
        }
        tree.nodes.items[item.node].first_child = if (children > 0) first else 0;
        tree.nodes.items[item.node].child_count = children;
    }
    const nodes = tree.nodes.items;
    var i = nodes.len;
    while (i > 1) {
        i -= 1;
        nodes[nodes[i].parent].size += nodes[i].size;
        nodes[nodes[i].parent].files += nodes[i].files;
    }
    if (report) |rep| rep.call(rep.context, .{ .files = files, .directories = temps.items.len - files, .bytes = bytes });
    return tree;
}

const none = std.math.maxInt(u32);

/// A Linux name (any bytes) as text the page can show: what is not UTF-8
/// becomes "?".
fn appendName(a: Allocator, names: *std.ArrayList(u8), name: []const u8) Allocator.Error!void {
    if (std.unicode.utf8ValidateSlice(name)) return names.appendSlice(a, name);
    for (name) |c| try names.append(a, if (c < 0x80) c else '?');
}

/// Compacts the distribution's virtual disk so Windows gets back what was
/// freed inside it: WSL stopped (every distribution), then diskpart.
/// Administrator only. Returns the disk's size after.
pub fn compact(a: Allocator, io: Io, distro: Distro) Error!u64 {
    if (builtin.os.tag != .windows) return error.NoWsl;
    try run(a, io, &.{ "wsl.exe", "--shutdown" }, .fromSeconds(120));
    // diskpart takes its commands from a file.
    var tmp_wide: [261]u16 = undefined;
    const tmp_len = GetTempPathW(tmp_wide.len, &tmp_wide);
    if (tmp_len == 0 or tmp_len > tmp_wide.len) return error.Failed;
    const tmp = try std.unicode.wtf16LeToWtf8Alloc(a, tmp_wide[0..tmp_len]);
    defer a.free(tmp);
    const script_path = try std.fs.path.join(a, &.{ tmp, "headroom-compact.txt" });
    defer a.free(script_path);
    const script = try std.fmt.allocPrint(a, "select vdisk file=\"{s}\"\r\nattach vdisk readonly\r\ncompact vdisk\r\ndetach vdisk\r\nexit\r\n", .{distro.disk});
    defer a.free(script);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script }) catch return error.Failed;
    defer Io.Dir.cwd().deleteFile(io, script_path) catch {};
    try run(a, io, &.{ "diskpart.exe", "/s", script_path }, .fromSeconds(3 * 3600));
    return diskSize(a, distro.disk);
}

fn run(a: Allocator, io: Io, argv: []const []const u8, timeout: Io.Duration) Error!void {
    const result = std.process.run(a, io, .{ .argv = argv, .timeout = .{ .duration = .{ .raw = timeout, .clock = .awake } } }) catch return error.Failed;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.Failed,
        else => return error.Failed,
    }
}

// ---- Windows' registry ----

const HKEY = *opaque {};
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x8000_0001)))))));
const KEY_READ: u32 = 0x20019;
const RRF_RT_REG_SZ: u32 = 0x02;
const RRF_RT_REG_DWORD: u32 = 0x10;

extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: [*:0]const u16, options: u32, sam: u32, result: *HKEY) callconv(.winapi) i32;
extern "advapi32" fn RegEnumKeyExW(key: HKEY, index: u32, name: [*]u16, name_len: *u32, reserved: ?*u32, class: ?[*]u16, class_len: ?*u32, time: ?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(key: HKEY, sub_key: ?[*:0]const u16, value_name: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, len: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;
extern "kernel32" fn GetCompressedFileSizeW(name: [*:0]const u16, high: *u32) callconv(.winapi) u32;
extern "kernel32" fn GetTempPathW(len: u32, buffer: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// A REG_SZ value of `sub_key` as UTF-8, null when there is none.
fn value(a: Allocator, key: HKEY, sub_key: [*:0]const u16, comptime name: []const u8) Allocator.Error!?[]const u8 {
    var data: [1024]u16 = undefined;
    var len: u32 = @sizeOf(@TypeOf(data));
    if (RegGetValueW(key, sub_key, std.unicode.utf8ToUtf16LeStringLiteral(name), RRF_RT_REG_SZ, null, &data, &len) != 0) return null;
    const chars = std.mem.sliceTo(data[0 .. len / 2], 0);
    return try std.unicode.wtf16LeToWtf8Alloc(a, chars);
}

// ---- Tests ----

const testing = std.testing;

fn find(tree: *const scan.Tree, parent: u32, name: []const u8) ?u32 {
    const node = tree.node(parent);
    for (0..node.child_count) |i| {
        const index = node.first_child + @as(u32, @intCast(i));
        if (std.mem.eql(u8, tree.name(index), name)) return index;
    }
    return null;
}

test "a tree from find's records" {
    const records = "d 8 2 20 1700000000.5 \x00" ++
        "d 8 10 3 1700000001.0 home\x00" ++
        "d 8 11 2 1700000002.0 home/ada\x00" ++
        "d 8 12 2 1700000003.0 home/ada/web\x00" ++
        "f 2000 13 1 1700000004.0 home/ada/web/package.json\x00" ++
        "d 8 14 2 1700000005.0 home/ada/web/node_modules\x00" ++
        "f 800 15 1 1600000000.0 home/ada/web/node_modules/a b.js\x00" ++
        "f 100 16 2 1700000006.0 home/ada/notes.md\x00" ++
        "f 100 16 2 1700000006.0 home/ada/same-notes.md\x00" ++
        "l 0 17 1 1700000007.0 home/ada/link\x00" ++
        "d 8 18 2 1700000008.0 etc\x00" ++
        "f 16 19 1 1700000009.0 etc/hostname\x00";
    var reader: Io.Reader = .fixed(records);
    var tree = try build(testing.allocator, &reader, "\\\\wsl.localhost\\Ubuntu", null, null);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.linux);
    try testing.expectEqualStrings("\\\\wsl.localhost\\Ubuntu", tree.root);
    const home = find(&tree, 0, "home").?;
    const ada = find(&tree, home, "ada").?;
    const web = find(&tree, ada, "web").?;
    const modules = find(&tree, web, "node_modules").?;
    try testing.expect(find(&tree, 0, "etc") != null);
    // A name with a space; blocks of 512 bytes; the mtime's whole seconds.
    const file = find(&tree, modules, "a b.js").?;
    try testing.expectEqual(@as(u64, 800 * 512), tree.node(file).size);
    try testing.expectEqual(@as(i64, 1_600_000_000), tree.node(file).mtime);
    // A hard link's second name takes nothing; a link nothing.
    try testing.expectEqual(@as(u64, 100 * 512), tree.node(find(&tree, ada, "notes.md").?).size + tree.node(find(&tree, ada, "same-notes.md").?).size);
    try testing.expectEqual(scan.Kind.link, tree.node(find(&tree, ada, "link").?).kind);
    // Children side by side, after their folder; totals summed.
    for (tree.nodes.items, 0..) |n, i| {
        if (n.child_count == 0) continue;
        try testing.expect(n.first_child > i);
    }
    try testing.expectEqual(@as(u64, 5), tree.node(0).files);
    try testing.expectEqual(tree.node(home).size + tree.node(find(&tree, 0, "etc").?).size, tree.node(0).size);
    const path = try tree.path(testing.allocator, file);
    defer testing.allocator.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "node_modules" ++ std.fs.path.sep_str ++ "a b.js"));
}

test "names that are not UTF-8" {
    var reader: Io.Reader = .fixed("d 8 1 2 1.0 \x00f 8 2 1 1.0 caf\xe9.txt\x00");
    var tree = try build(testing.allocator, &reader, "\\\\wsl.localhost\\x", null, null);
    defer tree.deinit(testing.allocator);
    try testing.expect(find(&tree, 0, "caf?.txt") != null);
}
