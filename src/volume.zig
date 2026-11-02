//! The disk a folder is on: its size and what is free, for the meter.

const std = @import("std");
const builtin = @import("builtin");

pub const Space = struct {
    total: u64,
    /// Free for this user (quotas and reserved blocks taken off).
    free: u64,
};

/// The space of the disk holding `path`; null if it cannot be told.
pub fn space(a: std.mem.Allocator, path: []const u8) ?Space {
    switch (builtin.os.tag) {
        .windows => {
            const wide = std.unicode.wtf8ToWtf16LeAllocZ(a, path) catch return null;
            defer a.free(wide);
            var free: u64 = 0;
            var total: u64 = 0;
            if (GetDiskFreeSpaceExW(wide.ptr, &free, &total, null) == .FALSE) return null;
            return .{ .total = total, .free = free };
        },
        .linux => {
            const z = a.dupeSentinel(u8, path, 0) catch return null;
            defer a.free(z);
            var st: Statvfs = undefined;
            if (statvfs(z.ptr, &st) != 0) return null;
            return .{ .total = st.blocks * st.frsize, .free = st.bavail * st.frsize };
        },
        else => return null,
    }
}

extern "kernel32" fn GetDiskFreeSpaceExW(
    directory: [*:0]const u16,
    free_to_caller: ?*u64,
    total: ?*u64,
    total_free: ?*u64,
) callconv(.winapi) std.os.windows.BOOL;

/// glibc's struct statvfs on 64-bit Linux.
const Statvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

test "the space of the current folder's disk" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;
    if (builtin.os.tag == .linux and !builtin.link_libc) return error.SkipZigTest;
    const s = space(std.testing.allocator, ".") orelse return error.TestUnexpectedResult;
    try std.testing.expect(s.total > 0 and s.free <= s.total);
}
