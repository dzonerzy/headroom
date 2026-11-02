//! The disks there are to scan: Windows' fixed and removable drives, Linux's
//! mounted filesystems that hold files (not /proc, /sys, snaps or the same
//! device mounted twice).

const std = @import("std");
const builtin = @import("builtin");
const volume = @import("volume.zig");

pub const Disk = struct {
    /// Where it is: "C:\", "/", "/mnt/data".
    path: []const u8,
    /// Its name: the volume label, or the mount point's.
    name: []const u8,
    total: u64,
    free: u64,
    /// A USB drive or a card: not watched by the alarm.
    removable: bool,
};

pub fn list(a: std.mem.Allocator, io: std.Io) ![]Disk {
    return switch (builtin.os.tag) {
        .windows => windows(a),
        .linux => linux(a, io),
        else => &.{},
    };
}

fn windows(a: std.mem.Allocator) ![]Disk {
    var out: std.ArrayList(Disk) = .empty;
    var buffer: [512]u16 = undefined;
    const len = GetLogicalDriveStringsW(buffer.len, &buffer);
    if (len == 0 or len > buffer.len) return out.toOwnedSlice(a);
    var start: usize = 0;
    while (start < len) {
        const end = std.mem.indexOfScalarPos(u16, buffer[0..len], start, 0) orelse len;
        const root = buffer[start..end :0];
        start = end + 1;
        const kind = GetDriveTypeW(root.ptr);
        const DRIVE_REMOVABLE = 2;
        const DRIVE_FIXED = 3;
        if (kind != DRIVE_FIXED and kind != DRIVE_REMOVABLE) continue;
        const path = std.unicode.wtf16LeToWtf8Alloc(a, root) catch continue;
        const space = volume.space(a, path) orelse continue;
        if (space.total == 0) continue;
        var label: [261]u16 = undefined;
        const name = if (GetVolumeInformationW(root.ptr, &label, label.len, null, null, null, null, 0) != .FALSE and label[0] != 0)
            std.unicode.wtf16LeToWtf8Alloc(a, std.mem.sliceTo(&label, 0)) catch "Local disk"
        else if (kind == DRIVE_REMOVABLE) "Removable disk" else "Local disk";
        try out.append(a, .{ .path = path, .name = name, .total = space.total, .free = space.free, .removable = kind == DRIVE_REMOVABLE });
    }
    return out.toOwnedSlice(a);
}

extern "kernel32" fn GetLogicalDriveStringsW(length: u32, buffer: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetVolumeInformationW(
    root: [*:0]const u16,
    name: [*]u16,
    name_size: u32,
    serial: ?*u32,
    max_component: ?*u32,
    flags: ?*u32,
    fs_name: ?[*]u16,
    fs_name_size: u32,
) callconv(.winapi) std.os.windows.BOOL;

/// Filesystems that hold people's files.
const real = [_][]const u8{ "ext2", "ext3", "ext4", "xfs", "btrfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "fuseblk", "zfs", "bcachefs", "jfs", "reiserfs", "hfsplus" };

fn linux(a: std.mem.Allocator, io: std.Io) ![]Disk {
    var out: std.ArrayList(Disk) = .empty;
    const mounts = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/mounts", a, .limited(1 << 20)) catch return out.toOwnedSlice(a);
    return parseMounts(a, mounts, true);
}

/// Disks from /proc/self/mounts' lines ("device mountpoint type options 0 0");
/// `measure`: with their space (false in tests).
pub fn parseMounts(a: std.mem.Allocator, mounts: []const u8, measure: bool) ![]Disk {
    var out: std.ArrayList(Disk) = .empty;
    var devices: std.ArrayList([]const u8) = .empty;
    defer devices.deinit(a);
    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const point = try unescape(a, fields.next() orelse continue);
        const kind = fields.next() orelse continue;
        const known = for (real) |r| {
            if (std.mem.eql(u8, r, kind)) break true;
        } else false;
        if (!known) continue;
        if (std.mem.startsWith(u8, point, "/snap/") or std.mem.startsWith(u8, point, "/boot")) continue;
        // The same device mounted again (a bind mount): its first place.
        const seen = for (devices.items) |d| {
            if (std.mem.eql(u8, d, device)) break true;
        } else false;
        if (seen) continue;
        try devices.append(a, device);
        var total: u64 = 0;
        var free: u64 = 0;
        if (measure) {
            const space = volume.space(a, point) orelse continue;
            total = space.total;
            free = space.free;
            if (total == 0) continue;
        }
        const name = if (std.mem.eql(u8, point, "/")) "System" else std.fs.path.basename(point);
        const removable = std.mem.startsWith(u8, point, "/media/") or std.mem.startsWith(u8, point, "/run/media/");
        try out.append(a, .{ .path = point, .name = name, .total = total, .free = free, .removable = removable });
    }
    return out.toOwnedSlice(a);
}

/// Mount points escape spaces and the like as \040 (octal).
fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |c| {
                try out.append(a, c);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

test "the disks in /proc/self/mounts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mounts =
        \\sysfs /sys sysfs rw,nosuid 0 0
        \\proc /proc proc rw 0 0
        \\/dev/nvme0n1p2 / ext4 rw,relatime 0 0
        \\/dev/nvme0n1p1 /boot/efi vfat rw 0 0
        \\/dev/sda1 /mnt/My\040Data ntfs3 rw 0 0
        \\/dev/nvme0n1p2 /var/lib/docker ext4 rw 0 0
        \\/dev/loop3 /snap/core/1 squashfs ro 0 0
        \\/dev/sdb1 /media/ada/USB vfat rw 0 0
        \\tmpfs /run tmpfs rw 0 0
    ;
    const disks = try parseMounts(arena.allocator(), mounts, false);
    try std.testing.expectEqual(@as(usize, 3), disks.len);
    try std.testing.expectEqualStrings("/", disks[0].path);
    try std.testing.expectEqualStrings("System", disks[0].name);
    try std.testing.expectEqualStrings("/mnt/My Data", disks[1].path);
    try std.testing.expectEqualStrings("My Data", disks[1].name);
    try std.testing.expect(disks[2].removable);
}

test "this computer's disks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const disks = try list(arena.allocator(), std.testing.io);
    if (builtin.os.tag == .windows) try std.testing.expect(disks.len >= 1);
    for (disks) |d| try std.testing.expect(d.free <= d.total);
}
