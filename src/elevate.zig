//! Administrator rights: whether Headroom has them, and (Windows) starting
//! itself again with them, asked through the system's prompt, to scan what
//! the user's rights cannot read (System Volume Information, other users'
//! profiles, WindowsApps).

const std = @import("std");
const builtin = @import("builtin");

pub fn isAdmin() bool {
    return switch (builtin.os.tag) {
        .windows => IsUserAnAdmin() != .FALSE,
        .linux => std.os.linux.geteuid() == 0,
        else => false,
    };
}

pub const Error = error{
    /// The prompt was declined, or the system refused.
    Declined,
    /// Not on Windows: a desktop app is not run as root on Linux.
    Unsupported,
    OutOfMemory,
};

/// This executable again, as administrator, scanning `path` once it starts.
/// The caller quits when it returns.
pub fn restart(a: std.mem.Allocator, io: std.Io, path: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const exe = std.process.executablePathAlloc(io, a) catch return error.Declined;
    defer a.free(exe);
    const quoted = try quote(a, path);
    defer a.free(quoted);
    const params = try std.fmt.allocPrint(a, "--scan {s}", .{quoted});
    defer a.free(params);

    const wide_exe = std.unicode.wtf8ToWtf16LeAllocZ(a, exe) catch return error.OutOfMemory;
    defer a.free(wide_exe);
    const wide_params = std.unicode.wtf8ToWtf16LeAllocZ(a, params) catch return error.OutOfMemory;
    defer a.free(wide_params);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    // Above 32: started. The prompt declined is 5 (access denied).
    const result = ShellExecuteW(null, verb, wide_exe.ptr, wide_params.ptr, null, 1);
    if (@intFromPtr(result) <= 32) return error.Declined;
}

/// `arg` as one argument of a Windows command line (CommandLineToArgvW's
/// rules): quoted, quotes escaped, backslashes before a quote doubled.
pub fn quote(a: std.mem.Allocator, arg: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        const times = if (c == '"') backslashes * 2 + 1 else backslashes;
        try out.appendNTimes(a, '\\', times);
        backslashes = 0;
        try out.append(a, c);
    }
    try out.appendNTimes(a, '\\', backslashes * 2);
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// The folder given as `--scan <path>`, if any.
pub fn scanArgument(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--scan") and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

extern "shell32" fn IsUserAnAdmin() callconv(.winapi) std.os.windows.BOOL;
extern "shell32" fn ShellExecuteW(
    window: ?*anyopaque,
    operation: ?[*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show: c_int,
) callconv(.winapi) ?*anyopaque;

test "quoting for a Windows command line" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "C:\\Users\\ada", "\"C:\\Users\\ada\"" },
        // The root: its backslash would escape the closing quote.
        .{ "C:\\", "\"C:\\\\\"" },
        .{ "D:\\My Files", "\"D:\\My Files\"" },
        .{ "say \"hi\"", "\"say \\\"hi\\\"\"" },
    };
    for (cases) |case| {
        const got = try quote(a, case[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "the --scan argument" {
    try std.testing.expectEqualStrings("C:\\", scanArgument(&.{ "headroom.exe", "--scan", "C:\\" }).?);
    try std.testing.expect(scanArgument(&.{"headroom.exe"}) == null);
    try std.testing.expect(scanArgument(&.{ "headroom.exe", "--scan" }) == null);
}
