//! Deleting from Headroom: to the Recycle Bin (Windows) or the Trash (Linux,
//! the freedesktop.org layout) by default, so it can be undone; for good
//! when asked. What the system needs is refused, what other programs rely
//! on is warned about.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Mode = enum {
    /// The Recycle Bin or the Trash: undone from there; the space comes back
    /// when it is emptied.
    trash,
    permanent,
};

pub const Error = error{
    /// Another program has it open.
    InUse,
    AccessDenied,
    NotFound,
    /// No Trash for it (another disk on Linux, too long a path for the
    /// Recycle Bin): delete it for good instead.
    TrashUnavailable,
    Failed,
    OutOfMemory,
};

/// Why `path` must not be deleted, or null. `home`: the user's folder;
/// `scanned`: the folder scanned (its contents may go, not it).
pub fn refusal(path: []const u8, home: []const u8, scanned: []const u8) ?[]const u8 {
    if (same(path, scanned)) return "the folder you scanned (delete what is in it instead)";
    if (builtin.os.tag == .windows) {
        // Inside a WSL distribution: Linux's folders, every user's home.
        var linux_buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (wslLinuxPath(&linux_buffer, path)) |linux| return linuxRefusal(linux, true);
        if (path.len <= 3) return "a whole disk";
        const name = std.fs.path.basename(path);
        for ([_][]const u8{ "pagefile.sys", "hiberfil.sys", "swapfile.sys" }) |memory| {
            if (std.ascii.eqlIgnoreCase(name, memory)) return "Windows' memory file: Windows manages it";
        }
        const drive = path[0..3];
        var buffer: [8][64]u8 = undefined;
        const system = [_][]const u8{
            join(&buffer[0], drive, "Windows"),
            join(&buffer[1], drive, "Program Files"),
            join(&buffer[2], drive, "Program Files (x86)"),
            join(&buffer[3], drive, "ProgramData"),
            join(&buffer[4], drive, "Users"),
            join(&buffer[5], drive, "System Volume Information"),
            join(&buffer[6], drive, "$Recycle.Bin"),
            join(&buffer[7], drive, "Recovery"),
        };
        for (system) |folder| {
            if (same(path, folder) or contains(path, folder)) return "a folder Windows needs";
        }
        if (inside(path, system[0])) return "inside the Windows folder";
    } else if (linuxRefusal(path, false)) |why| return why;
    if (home.len > 0 and (same(path, home) or contains(path, home))) return "your home folder";
    return null;
}

/// Linux's folders the system needs; with `every_home`, any user's home too
/// (inside a WSL distribution, where which one is the user's is not known).
fn linuxRefusal(path: []const u8, every_home: bool) ?[]const u8 {
    if (same(path, "/")) return "the whole system";
    for ([_][]const u8{ "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/etc", "/boot", "/var", "/opt", "/home", "/root", "/proc", "/sys", "/dev", "/run", "/snap", "/srv", "/mnt", "/media" }) |folder| {
        if (same(path, folder) or contains(path, folder)) return "a folder the system needs";
    }
    for ([_][]const u8{ "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/boot" }) |folder| {
        if (inside(path, folder)) return "part of the system";
    }
    if (every_home) {
        const parent = std.fs.path.dirnamePosix(std.mem.trimEnd(u8, path, "/")) orelse "";
        if (same(parent, "/home")) return "a user's home folder";
    }
    return null;
}

/// A WSL distribution's path as Windows sees it (\\wsl.localhost\<name>\…,
/// \\wsl$\<name>\…) as the distribution's own ("/usr/lib"); null for others.
pub fn wslLinuxPath(buffer: []u8, path: []const u8) ?[]const u8 {
    const rest = for ([_][]const u8{ "\\\\wsl.localhost\\", "\\\\wsl$\\", "//wsl.localhost/", "//wsl$/" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(path, prefix)) break path[prefix.len..];
    } else return null;
    // After the distribution's name.
    const at = std.mem.indexOfAny(u8, rest, "\\/") orelse rest.len;
    const inner = rest[at..];
    if (inner.len + 1 > buffer.len) return null;
    buffer[0] = '/';
    var len: usize = 1;
    for (std.mem.trimStart(u8, inner, "\\/")) |c| {
        buffer[len] = if (c == '\\') '/' else c;
        len += 1;
    }
    return buffer[0..len];
}

/// What deleting `path` breaks that is easy to miss, or null.
pub fn warning(path: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(path);
    for ([_][]const u8{ ".vhdx", ".vhd", ".vmdk", ".qcow2", ".vdi" }) |disk| {
        if (std.ascii.endsWithIgnoreCase(name, disk))
            return "This is a virtual disk (WSL, Docker or a virtual machine): everything inside it goes with it. Its own tool can shrink it instead.";
    }
    if (std.mem.eql(u8, name, ".git")) return "This is a repository's history: its commits and branches go with it.";
    return null;
}

/// Deletes `path` (a file or a folder with everything in it).
pub fn remove(a: std.mem.Allocator, io: Io, path: []const u8, mode: Mode, home: []const u8) Error!void {
    switch (mode) {
        .permanent => {
            Io.Dir.cwd().deleteTree(io, path) catch |err| return switch (err) {
                error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                error.FileBusy => error.InUse,
                else => error.Failed,
            };
        },
        .trash => switch (builtin.os.tag) {
            // The Recycle Bin does not take network paths (a WSL
            // distribution's): Windows would delete them for good.
            .windows => if (std.ascii.startsWithIgnoreCase(path, "\\\\")) return error.TrashUnavailable else try recycle(a, path),
            .linux => try trash(a, io, path, home),
            else => return error.TrashUnavailable,
        },
    }
}

/// Empties the Recycle Bin of the disk `path` is on (Windows: this user's;
/// Linux: the home Trash, `path` being it).
pub fn emptyBin(a: std.mem.Allocator, io: Io, path: []const u8) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const drive = std.unicode.wtf8ToWtf16LeAllocZ(a, path[0..@min(path.len, 3)]) catch return error.OutOfMemory;
            defer a.free(drive);
            const SHERB_NOCONFIRMATION = 0x1;
            const SHERB_NOPROGRESSUI = 0x2;
            const SHERB_NOSOUND = 0x4;
            const result = SHEmptyRecycleBinW(null, drive.ptr, SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND);
            // Already empty: E_UNEXPECTED (0x8000FFFF) on some systems.
            if (result != 0 and @as(u32, @bitCast(result)) != 0x8000FFFF) return error.Failed;
        },
        .linux => {
            const cwd = Io.Dir.cwd();
            for ([_][]const u8{ "files", "info" }) |part| {
                const folder = try std.fs.path.join(a, &.{ path, part });
                defer a.free(folder);
                var dir = cwd.openDir(io, folder, .{ .iterate = true }) catch continue;
                defer dir.close(io);
                // The names first: deleting while reading the folder skips some.
                var names: std.ArrayList([]u8) = .empty;
                defer {
                    for (names.items) |name| a.free(name);
                    names.deinit(a);
                }
                var it = dir.iterate();
                while (it.next(io) catch null) |entry| try names.append(a, try a.dupe(u8, entry.name));
                for (names.items) |name| {
                    dir.deleteTree(io, name) catch |err| switch (err) {
                        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
                        else => return error.Failed,
                    };
                }
            }
        },
        else => return error.Failed,
    }
}

extern "shell32" fn SHEmptyRecycleBinW(window: ?*anyopaque, root: ?[*:0]const u16, flags: u32) callconv(.winapi) i32;

/// Windows: SHFileOperation to the Recycle Bin. What it cannot take (too
/// big) is not deleted silently: Windows asks first (FOF_WANTNUKEWARNING).
fn recycle(a: std.mem.Allocator, path: []const u8) Error!void {
    const wide = std.unicode.wtf8ToWtf16LeAlloc(a, path) catch return error.OutOfMemory;
    defer a.free(wide);
    if (wide.len >= 260) return error.TrashUnavailable;
    // Two NULs: a list of one path.
    const from = try a.alloc(u16, wide.len + 2);
    defer a.free(from);
    @memcpy(from[0..wide.len], wide);
    from[wide.len] = 0;
    from[wide.len + 1] = 0;
    var operation: SHFILEOPSTRUCTW = .{
        .hwnd = null,
        .wFunc = FO_DELETE,
        .pFrom = from.ptr,
        .pTo = null,
        .fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING,
        .fAnyOperationsAborted = .FALSE,
        .hNameMappings = null,
        .lpszProgressTitle = null,
    };
    const result = SHFileOperationW(&operation);
    if (operation.fAnyOperationsAborted != .FALSE) return error.Failed;
    return switch (result) {
        0 => {},
        2, 3, 0x7C => error.NotFound,
        5, 0x78 => error.AccessDenied,
        32, 33 => error.InUse,
        else => error.Failed,
    };
}

/// Linux: the home Trash ($XDG_DATA_HOME/Trash, else ~/.local/share/Trash):
/// moved into files/, its origin in info/<name>.trashinfo. Only on the
/// home's filesystem (a rename); elsewhere TrashUnavailable.
fn trash(a: std.mem.Allocator, io: Io, path: []const u8, home: []const u8) Error!void {
    if (home.len == 0) return error.TrashUnavailable;
    const root = try std.fs.path.join(a, &.{ home, ".local", "share", "Trash" });
    defer a.free(root);
    const files = try std.fs.path.join(a, &.{ root, "files" });
    defer a.free(files);
    const info = try std.fs.path.join(a, &.{ root, "info" });
    defer a.free(info);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, files) catch return error.TrashUnavailable;
    cwd.createDirPath(io, info) catch return error.TrashUnavailable;

    // A name not taken yet: notes.md, notes.md.2, ...
    const base = std.fs.path.basename(path);
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = if (n == 1) try a.dupe(u8, base) else try std.fmt.allocPrint(a, "{s}.{d}", .{ base, n });
        defer a.free(name);
        const info_name = try std.fmt.allocPrint(a, "{s}.trashinfo", .{name});
        defer a.free(info_name);
        const info_path = try std.fs.path.join(a, &.{ info, info_name });
        defer a.free(info_path);
        // The info file first, created exclusively: it claims the name.
        var file = cwd.createFile(io, info_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.TrashUnavailable,
        };
        const record = try trashInfo(a, io, path);
        defer a.free(record);
        file.writeStreamingAll(io, record) catch {
            file.close(io);
            return error.TrashUnavailable;
        };
        file.close(io);
        const target = try std.fs.path.join(a, &.{ files, name });
        defer a.free(target);
        Io.Dir.renameAbsolute(path, target, io) catch |err| {
            cwd.deleteFile(io, info_path) catch {};
            return switch (err) {
                error.CrossDevice => error.TrashUnavailable,
                error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                error.FileNotFound => error.NotFound,
                else => error.Failed,
            };
        };
        return;
    }
}

/// [Trash Info]: the original path, percent-encoded, and when (UTC).
fn trashInfo(a: std.mem.Allocator, io: Io, path: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "[Trash Info]\nPath=");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.~", c) != null) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    const now = Io.Clock.real.now(io);
    const seconds: u64 = @intCast(@max(@divFloor(now.toNanoseconds(), std.time.ns_per_s), 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    try out.print(a, "\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
    return out.toOwnedSlice(a);
}

fn join(buffer: *[64]u8, drive: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ drive, name }) catch drive;
}

fn eqlPath(a: u8, b: u8) bool {
    const sa = if (a == '/') '\\' else a;
    const sb = if (b == '/') '\\' else b;
    if (builtin.os.tag == .windows) return std.ascii.toLower(sa) == std.ascii.toLower(sb);
    return a == b;
}

/// The same path (Windows: either slash, any case; a trailing separator ignored).
fn same(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "/\\");
    const y = std.mem.trimEnd(u8, b, "/\\");
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!eqlPath(p, q)) return false;
    return true;
}

/// Whether `inner` is under `outer`.
fn inside(inner: []const u8, outer: []const u8) bool {
    const o = std.mem.trimEnd(u8, outer, "/\\");
    if (inner.len <= o.len + 1) return false;
    for (inner[0..o.len], o) |p, q| if (!eqlPath(p, q)) return false;
    return inner[o.len] == '/' or inner[o.len] == '\\';
}

/// Whether `outer` holds `inner` (deleting it deletes that).
fn contains(outer: []const u8, inner: []const u8) bool {
    return inside(inner, outer);
}

const FO_DELETE: c_uint = 3;
const FOF_SILENT: u16 = 0x0004;
const FOF_NOCONFIRMATION: u16 = 0x0010;
const FOF_ALLOWUNDO: u16 = 0x0040;
const FOF_NOERRORUI: u16 = 0x0400;
const FOF_WANTNUKEWARNING: u16 = 0x4000;

const SHFILEOPSTRUCTW = extern struct {
    hwnd: ?*anyopaque,
    wFunc: c_uint,
    pFrom: [*]const u16,
    pTo: ?[*]const u16,
    fFlags: u16,
    fAnyOperationsAborted: std.os.windows.BOOL,
    hNameMappings: ?*anyopaque,
    lpszProgressTitle: ?[*:0]const u16,
};

extern "shell32" fn SHFileOperationW(operation: *SHFILEOPSTRUCTW) callconv(.winapi) c_int;

// ---- Tests ----

const testing = std.testing;

test "what is refused" {
    if (builtin.os.tag == .windows) {
        const home = "C:\\Users\\ada";
        const scanned = "C:\\";
        try testing.expect(refusal("C:\\", home, "D:\\") != null);
        try testing.expect(refusal("C:\\Windows", home, scanned) != null);
        try testing.expect(refusal("c:\\windows\\System32\\drivers", home, scanned) != null);
        try testing.expect(refusal("C:\\Program Files", home, scanned) != null);
        try testing.expect(refusal("C:\\Users", home, scanned) != null);
        try testing.expect(refusal("C:\\Users\\ada", home, scanned) != null);
        try testing.expect(refusal("C:\\pagefile.sys", home, scanned) != null);
        try testing.expect(refusal("C:\\Users\\ada\\Downloads", home, "C:\\Users\\ada\\Downloads") != null);
        // What is in them may go.
        try testing.expect(refusal("C:\\Users\\ada\\Downloads\\big.iso", home, scanned) == null);
        try testing.expect(refusal("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Game", home, scanned) == null);
        try testing.expect(refusal("C:\\Windows.old", home, scanned) == null);
    } else {
        const home = "/home/ada";
        try testing.expect(refusal("/", home, "/") != null);
        try testing.expect(refusal("/usr", home, "/") != null);
        try testing.expect(refusal("/usr/lib/libz.so", home, "/") != null);
        try testing.expect(refusal("/home", home, "/") != null);
        try testing.expect(refusal("/home/ada", home, "/") != null);
        try testing.expect(refusal("/home/ada/.cache", home, "/") == null);
        try testing.expect(refusal("/var/lib/docker", home, "/") == null);
    }
}

test "a WSL distribution's paths, as Linux's" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/ada/web", wslLinuxPath(&buffer, "\\\\wsl.localhost\\Ubuntu\\home\\ada\\web").?);
    try std.testing.expectEqualStrings("/", wslLinuxPath(&buffer, "\\\\wsl$\\Ubuntu").?);
    try std.testing.expect(wslLinuxPath(&buffer, "C:\\Users\\ada") == null);
    if (builtin.os.tag != .windows) return;
    const scanned = "\\\\wsl.localhost\\Ubuntu";
    try std.testing.expect(refusal("\\\\wsl.localhost\\Ubuntu\\usr\\lib\\x", "C:\\Users\\ada", scanned) != null);
    try std.testing.expect(refusal("\\\\wsl.localhost\\Ubuntu\\home\\ada", "C:\\Users\\ada", scanned) != null);
    try std.testing.expect(refusal("\\\\wsl.localhost\\Ubuntu\\mnt", "C:\\Users\\ada", scanned) != null);
    try std.testing.expect(refusal("\\\\wsl.localhost\\Ubuntu\\home\\ada\\web\\node_modules", "C:\\Users\\ada", scanned) == null);
    try std.testing.expect(refusal("\\\\wsl.localhost\\Ubuntu\\var\\lib\\docker", "C:\\Users\\ada", scanned) == null);
    // No Recycle Bin over the share.
    try std.testing.expectError(error.TrashUnavailable, remove(std.testing.allocator, std.testing.io, "\\\\wsl.localhost\\Ubuntu\\tmp\\x", .trash, ""));
}

test "warnings" {
    try testing.expect(warning("C:\\Users\\ada\\AppData\\Local\\Docker\\wsl\\disk\\docker_data.vhdx") != null);
    try testing.expect(warning("/home/ada/project/.git") != null);
    try testing.expect(warning("/home/ada/notes.md") == null);
}

test "to the Trash or the Recycle Bin, and for good" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "doomed/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "doomed/inner/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "b" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const doomed = try std.fs.path.join(testing.allocator, &.{ root, "doomed" });
    defer testing.allocator.free(doomed);
    const gone = try std.fs.path.join(testing.allocator, &.{ root, "gone.txt" });
    defer testing.allocator.free(gone);

    try remove(testing.allocator, io, doomed, .permanent, "");
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "doomed", .{}));

    // The Trash, in a home of the test's own (Linux). On Windows the Recycle
    // Bin is the user's own: not touched by a test.
    if (builtin.os.tag != .linux) return;
    const home = try std.fs.path.join(testing.allocator, &.{ root, "home" });
    defer testing.allocator.free(home);
    try remove(testing.allocator, io, gone, .trash, home);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "gone.txt", .{}));
    try tmp.dir.access(io, "home/.local/share/Trash/files/gone.txt", .{});
    const record = try tmp.dir.readFileAlloc(io, "home/.local/share/Trash/info/gone.txt.trashinfo", testing.allocator, .limited(4096));
    defer testing.allocator.free(record);
    try testing.expect(std.mem.startsWith(u8, record, "[Trash Info]\nPath=/"));
    try testing.expect(std.mem.indexOf(u8, record, "DeletionDate=") != null);
}
