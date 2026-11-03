//! Free space over time, per disk: a sample an hour, two weeks kept, so the
//! tray can tell a disk losing space fast ("C:\ lost 12 GB today") and the
//! popover can draw the last days. And the folders scanned, newest last:
//! which one to scan again to say where the space went.
//!
//! Plume-free; the file is <data_dir>/space.tsv: "disk\tseconds\tfree\ttotal".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Sample = struct { disk: []const u8, time: i64, free: u64, total: u64 };

pub const hour = 3600;
pub const day = 24 * hour;
/// How long samples are kept.
pub const keep = 14 * day;

pub const History = struct {
    /// Oldest first; disks' names owned by `names`.
    samples: std.ArrayList(Sample) = .empty,
    names: std.heap.ArenaAllocator,

    pub fn init(a: Allocator) History {
        return .{ .names = .init(a) };
    }

    pub fn deinit(h: *History, a: Allocator) void {
        h.samples.deinit(a);
        h.names.deinit();
    }

    /// `disk`'s free space at `now`: kept if its last sample is an hour old
    /// (or there is none); samples older than two weeks go.
    pub fn record(h: *History, a: Allocator, disk: []const u8, now: i64, free: u64, total: u64) Allocator.Error!bool {
        const previous = h.last(disk);
        if (previous) |s| if (now - s.time < hour) return false;
        const name = if (previous) |s| s.disk else try h.names.allocator().dupe(u8, disk);
        try h.samples.append(a, .{ .disk = name, .time = now, .free = free, .total = total });
        // Oldest first: what is too old is at the start.
        var old: usize = 0;
        while (old < h.samples.items.len and now - h.samples.items[old].time > keep) old += 1;
        if (old > 0) h.samples.replaceRangeAssumeCapacity(0, old, &.{});
        return true;
    }

    fn last(h: *const History, disk: []const u8) ?Sample {
        var i = h.samples.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, h.samples.items[i].disk, disk)) return h.samples.items[i];
        }
        return null;
    }

    /// How much free space `disk` lost within `window` before `now`: the
    /// most it had then minus what it has (`free`); 0 if it gained.
    pub fn lost(h: *const History, disk: []const u8, now: i64, window: i64, free: u64) u64 {
        var most: u64 = free;
        for (h.samples.items) |s| {
            if (now - s.time > window or !std.mem.eql(u8, s.disk, disk)) continue;
            most = @max(most, s.free);
        }
        return most - free;
    }

    /// `disk`'s samples since `since`, oldest first, in `a`.
    pub fn series(h: *const History, a: Allocator, disk: []const u8, since: i64) Allocator.Error![]Sample {
        var out: std.ArrayList(Sample) = .empty;
        errdefer out.deinit(a);
        for (h.samples.items) |s| {
            if (s.time >= since and std.mem.eql(u8, s.disk, disk)) try out.append(a, s);
        }
        return out.toOwnedSlice(a);
    }

    pub fn load(a: Allocator, io: Io, path: []const u8) History {
        var h: History = .init(a);
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch return h;
        defer a.free(text);
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            const disk = fields.next() orelse continue;
            const time = std.fmt.parseInt(i64, fields.next() orelse continue, 10) catch continue;
            const free = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
            const total = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
            const name = for (h.samples.items) |s| {
                if (std.mem.eql(u8, s.disk, disk)) break s.disk;
            } else h.names.allocator().dupe(u8, disk) catch continue;
            h.samples.append(a, .{ .disk = name, .time = time, .free = free, .total = total }) catch break;
        }
        return h;
    }

    pub fn save(h: *const History, a: Allocator, io: Io, path: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        for (h.samples.items) |s| out.writer.print("{s}\t{d}\t{d}\t{d}\n", .{ s.disk, s.time, s.free, s.total }) catch return;
        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() }) catch {};
    }
};

/// Whether losing `lost` bytes of a `total`-byte disk in a day is worth
/// telling: 10 GB, or 5% of a smaller disk.
pub fn alarming(lost: u64, total: u64) bool {
    const ten_gb: u64 = 10 * 1000 * 1000 * 1000;
    return lost >= @min(ten_gb, total / 20) and lost > 0;
}

/// The folders scanned, newest last (at most 20), in <data_dir>/scanned.txt:
/// which to scan again for a disk.
pub fn rememberScan(a: Allocator, io: Io, file: []const u8, folder: []const u8) void {
    const old = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch "";
    defer if (old.len > 0) a.free(old);
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(a);
    var lines = std.mem.tokenizeAny(u8, old, "\r\n");
    while (lines.next()) |line| if (!std.mem.eql(u8, line, folder)) kept.append(a, line) catch return;
    kept.append(a, folder) catch return;
    const from = kept.items.len -| 20;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (kept.items[from..]) |line| out.writer.print("{s}\n", .{line}) catch return;
    if (std.fs.path.dirname(file)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = out.written() }) catch {};
}

/// The folder scanned last on `disk` (a path starting with it), in `a`.
pub fn lastScanOn(a: Allocator, io: Io, file: []const u8, disk: []const u8) ?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch return null;
    defer a.free(text);
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (line.len >= disk.len and std.ascii.eqlIgnoreCase(line[0..disk.len], disk)) found = line;
    }
    return if (found) |f| a.dupe(u8, f) catch null else null;
}

// ---- Tests ----

const testing = std.testing;
const GB: u64 = 1000 * 1000 * 1000;

test "a sample an hour, two weeks kept, what was lost in a day" {
    const a = testing.allocator;
    var h: History = .init(a);
    defer h.deinit(a);
    const start: i64 = 1_760_000_000;
    // Every 10 minutes for 15 days: one an hour is kept, the first day goes.
    var t = start;
    while (t < start + 15 * day) : (t += 600) _ = try h.record(a, "C:\\", t, 300 * GB, 1000 * GB);
    try testing.expect(h.samples.items.len <= 14 * 24 + 1);
    // The last kept an hour before the end at most; two weeks before it, the oldest.
    try testing.expect(h.samples.items[0].time >= t - keep - hour);
    // Another disk on its own.
    try testing.expect(try h.record(a, "D:\\", t, 50 * GB, 100 * GB));
    // 12 GB less now than within the day: lost 12 GB.
    try testing.expectEqual(12 * GB, h.lost("C:\\", t, day, 288 * GB));
    try testing.expectEqual(@as(u64, 0), h.lost("C:\\", t, day, 310 * GB));
    try testing.expect(alarming(12 * GB, 1000 * GB));
    try testing.expect(!alarming(3 * GB, 1000 * GB));
    // A small disk: 5% of it.
    try testing.expect(alarming(6 * GB, 100 * GB));
    try testing.expect(!alarming(4 * GB, 100 * GB));
    const days = try h.series(a, "D:\\", 0);
    defer a.free(days);
    try testing.expectEqual(@as(usize, 1), days.len);
}

test "saved and loaded; the folders scanned per disk" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const space = try std.fs.path.join(a, &.{ dir, "space.tsv" });
    defer a.free(space);
    {
        var h: History = .init(a);
        defer h.deinit(a);
        _ = try h.record(a, "C:\\", 1000, 5 * GB, 10 * GB);
        _ = try h.record(a, "C:\\", 1000 + hour, 4 * GB, 10 * GB);
        h.save(a, io, space);
    }
    var loaded = History.load(a, io, space);
    defer loaded.deinit(a);
    try testing.expectEqual(@as(usize, 2), loaded.samples.items.len);
    try testing.expectEqual(4 * GB, loaded.samples.items[1].free);

    const scanned = try std.fs.path.join(a, &.{ dir, "scanned.txt" });
    defer a.free(scanned);
    rememberScan(a, io, scanned, "C:\\Users\\ada");
    rememberScan(a, io, scanned, "D:\\games");
    rememberScan(a, io, scanned, "C:\\Users\\ada\\work");
    const newest = lastScanOn(a, io, scanned, "C:\\").?;
    defer a.free(newest);
    try testing.expectEqualStrings("C:\\Users\\ada\\work", newest);
    try testing.expect(lastScanOn(a, io, scanned, "E:\\") == null);
}
