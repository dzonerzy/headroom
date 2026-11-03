//! An NTFS volume read through its file table (the MFT), as administrators
//! can on Windows: every file's names and allocation in one sequential read,
//! seconds for a whole disk, and a file with several hard links counted once
//! (a folder-by-folder scan counts each link).
//!
//! The same reading works on a volume (\\.\C:) and on an image file (the
//! tests'). From the boot sector: where the MFT is; from the MFT's first
//! record: where the rest of it is. Each record, its fixups applied, gives
//! the file's names (one per hard link, with the folder it is in), whether it
//! is a folder or a reparse point (a junction: not followed), and what it
//! takes on the disk (its data streams, compressed or sparse ones by what is
//! allocated, and a folder's index).

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{ NotNtfs, Corrupt, ReadFailed, Canceled, NotFound } || Allocator.Error;

/// Where bytes come from: a volume or an image.
pub const Source = struct {
    file: Io.File,
    io: Io,
    /// Reads must be sector-aligned on a volume: the buffer and the offsets.
    sector: u32 = 512,

    fn read(s: Source, offset: u64, buffer: []u8) Error!void {
        const n = s.file.readPositionalAll(s.io, buffer, offset) catch return error.ReadFailed;
        if (n != buffer.len) return error.ReadFailed;
    }
};

const Run = struct { lcn: u64, clusters: u64 };

/// Buffers a volume reads into: sector-aligned (a page, for any sector size).
const page: std.mem.Alignment = .fromByteUnits(4096);

const Geometry = struct {
    sector: u32,
    cluster: u32,
    record: u32,
    mft_lcn: u64,
};

fn geometry(src: Source) Error!Geometry {
    var boot: [512]u8 align(4096) = undefined;
    try src.read(0, &boot);
    if (!std.mem.eql(u8, boot[3..11], "NTFS    ")) return error.NotNtfs;
    const sector = std.mem.readInt(u16, boot[0x0B..0x0D], .little);
    const spc_raw = boot[0x0D];
    const sectors_per_cluster: u32 = if (spc_raw <= 0x80) spc_raw else @as(u32, 1) << @intCast(256 - @as(u32, spc_raw));
    const cluster = sector * sectors_per_cluster;
    const mft_lcn = std.mem.readInt(u64, boot[0x30..0x38], .little);
    const per_record: i8 = @bitCast(boot[0x40]);
    const record: u32 = if (per_record > 0) @as(u32, @intCast(per_record)) * cluster else @as(u32, 1) << @intCast(-@as(i32, per_record));
    if (sector < 256 or cluster == 0 or record < 256 or record > 65536) return error.Corrupt;
    return .{ .sector = sector, .cluster = cluster, .record = record, .mft_lcn = mft_lcn };
}

/// A record's sectors restored from its update sequence array; false if the
/// record is not one (no "FILE", or torn).
fn fixup(record: []u8, sector: u32) bool {
    if (!std.mem.eql(u8, record[0..4], "FILE")) return false;
    const usa_offset = std.mem.readInt(u16, record[4..6], .little);
    const usa_count = std.mem.readInt(u16, record[6..8], .little);
    if (usa_count == 0 or usa_offset + usa_count * 2 > record.len) return false;
    const usn = std.mem.readInt(u16, record[usa_offset..][0..2], .little);
    var i: usize = 1;
    while (i < usa_count) : (i += 1) {
        const end = i * sector;
        if (end > record.len) return false;
        if (std.mem.readInt(u16, record[end - 2 ..][0..2], .little) != usn) return false;
        record[end - 2 ..][0..2].* = record[usa_offset + i * 2 ..][0..2].*;
    }
    return true;
}

/// An attribute of a record, while walking them.
const Attribute = struct {
    kind: u32,
    bytes: []const u8,

    fn resident(a: Attribute) bool {
        return a.bytes[8] == 0;
    }
    fn named(a: Attribute) bool {
        return a.bytes[9] != 0;
    }
    fn flags(a: Attribute) u16 {
        return std.mem.readInt(u16, a.bytes[0x0C..0x0E], .little);
    }
    fn value(a: Attribute) ?[]const u8 {
        if (!a.resident() or a.bytes.len < 0x18) return null;
        const len = std.mem.readInt(u32, a.bytes[0x10..0x14], .little);
        const off = std.mem.readInt(u16, a.bytes[0x14..0x16], .little);
        if (off + len > a.bytes.len) return null;
        return a.bytes[off..][0..len];
    }
    fn startVcn(a: Attribute) u64 {
        return std.mem.readInt(u64, a.bytes[0x10..0x18], .little);
    }
    /// What a non-resident attribute takes on the disk (the first extent's
    /// header holds it): compressed and sparse ones by what is allocated.
    fn allocated(a: Attribute) u64 {
        if (a.resident() or a.bytes.len < 0x40 or a.startVcn() != 0) return 0;
        const compressed_or_sparse = a.flags() & (0x0001 | 0x8000) != 0;
        if (compressed_or_sparse and a.bytes.len >= 0x48) return std.mem.readInt(u64, a.bytes[0x40..0x48], .little);
        return std.mem.readInt(u64, a.bytes[0x28..0x30], .little);
    }
    fn dataSize(a: Attribute) u64 {
        if (a.resident() or a.bytes.len < 0x38) return 0;
        return std.mem.readInt(u64, a.bytes[0x30..0x38], .little);
    }
    fn runs(a: Attribute, alloc: Allocator, out: *std.ArrayList(Run)) Error!void {
        if (a.resident()) return;
        const off = std.mem.readInt(u16, a.bytes[0x20..0x22], .little);
        if (off >= a.bytes.len) return error.Corrupt;
        var p = a.bytes[off..];
        var lcn: i64 = 0;
        while (p.len > 0 and p[0] != 0) {
            const len_size = p[0] & 0x0F;
            const off_size = p[0] >> 4;
            if (len_size == 0 or len_size > 8 or off_size > 8 or 1 + len_size + off_size > p.len) return error.Corrupt;
            var clusters: u64 = 0;
            for (0..len_size) |i| clusters |= @as(u64, p[1 + i]) << @intCast(i * 8);
            if (off_size == 0) {
                // A sparse run: nothing on the disk.
                try out.append(alloc, .{ .lcn = std.math.maxInt(u64), .clusters = clusters });
            } else {
                var delta: i64 = 0;
                for (0..off_size) |i| delta |= @as(i64, p[1 + len_size + i]) << @intCast(i * 8);
                // Sign-extended.
                const shift: u6 = @intCast(64 - @as(u32, off_size) * 8);
                delta = (delta << shift) >> shift;
                lcn += delta;
                try out.append(alloc, .{ .lcn = @intCast(lcn), .clusters = clusters });
            }
            p = p[1 + len_size + off_size ..];
        }
    }
};

fn attributes(record: []const u8) AttributeIterator {
    const first = std.mem.readInt(u16, record[0x14..0x16], .little);
    return .{ .record = record, .at = first };
}

const AttributeIterator = struct {
    record: []const u8,
    at: usize,

    fn next(it: *AttributeIterator) ?Attribute {
        if (it.at + 16 > it.record.len) return null;
        const kind = std.mem.readInt(u32, it.record[it.at..][0..4], .little);
        if (kind == 0xFFFFFFFF) return null;
        const len = std.mem.readInt(u32, it.record[it.at + 4 ..][0..4], .little);
        if (len < 16 or it.at + len > it.record.len) return null;
        const a: Attribute = .{ .kind = kind, .bytes = it.record[it.at..][0..len] };
        it.at += len;
        return a;
    }
};

const AT_STANDARD_INFORMATION = 0x10;
const AT_ATTRIBUTE_LIST = 0x20;
const AT_FILE_NAME = 0x30;
const AT_DATA = 0x80;
const AT_INDEX_ALLOCATION = 0xA0;
const AT_REPARSE_POINT = 0xC0;

/// The MFT as one run list (record 0's $DATA, with the extents its
/// attribute list puts in other records).
fn mftRuns(alloc: Allocator, src: Source, g: Geometry) Error!struct { runs: []Run, records: u64 } {
    const record = try alloc.alignedAlloc(u8, page, @max(g.record, 4096));
    defer alloc.free(record);
    const rec = record[0..g.record];
    try src.read(g.mft_lcn * g.cluster, record[0..@max(g.record, g.sector)]);
    if (!fixup(rec, g.sector)) return error.Corrupt;
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(alloc);
    var size: u64 = 0;
    var others: std.ArrayList(u64) = .empty;
    defer others.deinit(alloc);
    var it = attributes(rec);
    while (it.next()) |a| {
        if (a.kind == AT_DATA and !a.named()) {
            if (a.startVcn() == 0) size = a.dataSize();
            try a.runs(alloc, &runs);
        } else if (a.kind == AT_ATTRIBUTE_LIST) {
            // Entries: type, length, ..., the record holding it (at 0x10).
            if (a.value()) |list| {
                var p: usize = 0;
                while (p + 0x18 <= list.len) {
                    const kind = std.mem.readInt(u32, list[p..][0..4], .little);
                    const len = std.mem.readInt(u16, list[p + 4 ..][0..2], .little);
                    if (len == 0) break;
                    const ref = std.mem.readInt(u64, list[p + 0x10 ..][0..8], .little) & 0xFFFF_FFFF_FFFF;
                    if (kind == AT_DATA and ref != 0) try others.append(alloc, ref);
                    p += len;
                }
            }
        }
    }
    // The $DATA extents in other records (a very fragmented MFT).
    for (others.items) |number| {
        const offset = recordOffset(runs.items, g, number) orelse return error.Corrupt;
        try src.read(offset, record[0..@max(g.record, g.sector)]);
        if (!fixup(rec, g.sector)) continue;
        var more = attributes(rec);
        while (more.next()) |a| {
            if (a.kind == AT_DATA and !a.named() and a.startVcn() != 0) try a.runs(alloc, &runs);
        }
    }
    if (size == 0) return error.Corrupt;
    return .{ .runs = try runs.toOwnedSlice(alloc), .records = size / g.record };
}

fn recordOffset(runs: []const Run, g: Geometry, number: u64) ?u64 {
    var byte = number * g.record;
    for (runs) |r| {
        const run_bytes = r.clusters * g.cluster;
        if (byte < run_bytes) {
            if (r.lcn == std.math.maxInt(u64)) return null;
            return r.lcn * g.cluster + byte;
        }
        byte -= run_bytes;
    }
    return null;
}

/// One record's facts.
const File = struct {
    size: u64 = 0,
    used: bool = false,
    dir: bool = false,
    reparse: bool = false,
    /// Last written, seconds since 1970 ($STANDARD_INFORMATION's: $FILE_NAME's
    /// times change only with the name).
    mtime: u32 = 0,
};

const Link = struct { parent: u32, child: u32, name_start: u32, name_len: u16 };

pub const Options = struct {
    report: ?scan.Report = null,
    cancel: ?*const std.atomic.Value(bool) = null,
};

/// The tree under `components` (folder names from the volume's root) of the
/// volume or image `src`; the tree's root is named `root_name`.
pub fn read(alloc: Allocator, src: Source, root_name: []const u8, components: []const []const u8, options: Options) Error!scan.Tree {
    const g = try geometry(src);
    const mft = try mftRuns(alloc, src, g);
    defer alloc.free(mft.runs);
    const count: u32 = @intCast(@min(mft.records, std.math.maxInt(u32)));

    const files = try alloc.alloc(File, count);
    defer alloc.free(files);
    @memset(files, .{});
    var links: std.ArrayList(Link) = .empty;
    defer links.deinit(alloc);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(alloc);

    // The MFT, run by run, a megabyte at a time.
    const chunk_records = @max(1, (1 << 20) / g.record);
    const chunk = try alloc.alignedAlloc(u8, page, chunk_records * g.record);
    defer alloc.free(chunk);
    var number: u32 = 0;
    for (mft.runs) |r| {
        if (r.lcn == std.math.maxInt(u64)) {
            number +|= @intCast(r.clusters * g.cluster / g.record);
            continue;
        }
        var done: u64 = 0;
        const run_bytes = r.clusters * g.cluster;
        while (done < run_bytes and number < count) {
            if (options.cancel) |c| if (c.load(.monotonic)) return error.Canceled;
            const want: usize = @intCast(@min(run_bytes - done, chunk.len));
            try src.read(r.lcn * g.cluster + done, chunk[0..want]);
            var k: usize = 0;
            while (k + g.record <= want and number < count) : (k += g.record) {
                try parseRecord(alloc, chunk[k..][0..g.record], g, number, files, &links, &names);
                number += 1;
            }
            done += want;
            if (options.report) |rep| rep.call(rep.context, .{ .files = number, .directories = 0, .bytes = 0, .unreadable = 0 });
        }
    }

    return build(alloc, files, links.items, names.items, root_name, components);
}

fn parseRecord(alloc: Allocator, record: []u8, g: Geometry, number: u32, files: []File, links: *std.ArrayList(Link), names: *std.ArrayList(u8)) Error!void {
    if (!fixup(record, g.sector)) return;
    const flags = std.mem.readInt(u16, record[0x16..0x18], .little);
    if (flags & 0x01 == 0) return; // not in use
    const base_ref = std.mem.readInt(u64, record[0x20..0x28], .little) & 0xFFFF_FFFF_FFFF;
    // An extension record's attributes are its base record's.
    const owner: u32 = if (base_ref != 0) @intCast(@min(base_ref, files.len - 1)) else number;
    const f = &files[owner];
    if (base_ref == 0) {
        f.used = true;
        f.dir = flags & 0x02 != 0;
    }
    var it = attributes(record);
    while (it.next()) |a| switch (a.kind) {
        AT_STANDARD_INFORMATION => {
            const v = a.value() orelse continue;
            if (v.len >= 0x10) f.mtime = scan.stamp(scan.unixSeconds(std.mem.readInt(i64, v[0x08..0x10], .little)));
        },
        AT_FILE_NAME => {
            const v = a.value() orelse continue;
            if (v.len < 0x42) continue;
            const namespace = v[0x41];
            if (namespace == 2) continue; // the DOS 8.3 name of a long one
            const parent: u32 = @intCast(std.mem.readInt(u64, v[0..8], .little) & 0xFFFF_FFFF);
            const chars = v[0x40];
            if (0x42 + @as(usize, chars) * 2 > v.len) continue;
            const wide = std.mem.bytesAsSlice(u16, v[0x42..][0 .. @as(usize, chars) * 2]);
            var buffer: [255 * 3]u8 = undefined;
            var wide_copy: [255]u16 = undefined;
            for (wide, 0..) |c, i| wide_copy[i] = c;
            const len = std.unicode.wtf16LeToWtf8(&buffer, wide_copy[0..wide.len]);
            const start: u32 = @intCast(names.items.len);
            try names.appendSlice(alloc, buffer[0..len]);
            try links.append(alloc, .{ .parent = parent, .child = owner, .name_start = start, .name_len = @intCast(len) });
        },
        AT_DATA, AT_INDEX_ALLOCATION => f.size += a.allocated(),
        AT_REPARSE_POINT => f.reparse = true,
        else => {},
    };
}

/// The scan's tree from the records: breadth first from the folder asked
/// for, each folder's children side by side; a file reached again by
/// another of its names takes no size there.
fn build(alloc: Allocator, files: []const File, links: []const Link, names: []const u8, root_name: []const u8, components: []const []const u8) Error!scan.Tree {
    // Children by parent (counting sort).
    const n = files.len;
    const start = try alloc.alloc(u32, n + 1);
    defer alloc.free(start);
    @memset(start, 0);
    for (links) |l| {
        if (l.parent < n and l.child != l.parent and files[l.child].used) start[l.parent + 1] += 1;
    }
    for (1..n + 1) |i| start[i] += start[i - 1];
    const order = try alloc.alloc(u32, start[n]);
    defer alloc.free(order);
    const fill = try alloc.dupe(u32, start[0..n]);
    defer alloc.free(fill);
    for (links, 0..) |l, i| {
        if (l.parent < n and l.child != l.parent and files[l.child].used) {
            order[fill[l.parent]] = @intCast(i);
            fill[l.parent] += 1;
        }
    }
    const children = struct {
        fn of(s: []const u32, o: []const u32, record: u32) []const u32 {
            return o[s[record]..s[record + 1]];
        }
    }.of;

    // The folder asked for, by its names from the root (record 5), any case.
    var at: u32 = 5;
    for (components) |part| {
        const next = for (children(start, order, at)) |li| {
            const l = links[li];
            if (std.ascii.eqlIgnoreCase(names[l.name_start..][0..l.name_len], part)) break l.child;
        } else return error.NotFound;
        at = next;
    }

    var tree: scan.Tree = .{ .root = try alloc.dupeSentinel(u8, root_name, 0) };
    errdefer tree.deinit(alloc);
    try tree.names.appendSlice(alloc, root_name);
    try tree.nodes.append(alloc, .{ .parent = 0, .name_start = 0, .name_len = scan.nameLength(root_name.len), .kind = .directory, .size = files[at].size, .files = 0 });

    const counted = try std.DynamicBitSetUnmanaged.initEmpty(alloc, n);
    var seen = counted;
    defer seen.deinit(alloc);
    var queue: std.ArrayList(struct { record: u32, node: u32 }) = .empty;
    defer queue.deinit(alloc);
    try queue.append(alloc, .{ .record = at, .node = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const item = queue.items[head];
        const kids = children(start, order, item.record);
        const first: u32 = @intCast(tree.nodes.items.len);
        tree.nodes.items[item.node].first_child = first;
        tree.nodes.items[item.node].child_count = @intCast(kids.len);
        for (kids) |li| {
            const l = links[li];
            const f = files[l.child];
            const name_start: u32 = @intCast(tree.names.items.len);
            try tree.names.appendSlice(alloc, names[l.name_start..][0..l.name_len]);
            const kind: scan.Kind = if (f.dir) (if (f.reparse) .link else .directory) else .file;
            // The first name reached takes the size; the others none.
            const first_time = !seen.isSet(l.child);
            seen.set(l.child);
            const index: u32 = @intCast(tree.nodes.items.len);
            try tree.nodes.append(alloc, .{
                .parent = item.node,
                .name_start = name_start,
                .name_len = l.name_len,
                .kind = kind,
                .size = if (first_time and kind != .link) f.size else 0,
                .files = @intFromBool(first_time and kind == .file),
                .mtime = f.mtime,
            });
            if (kind == .directory and first_time) try queue.append(alloc, .{ .record = l.child, .node = index });
        }
    }

    // Totals, as the scanner sums them.
    const nodes = tree.nodes.items;
    var i = nodes.len;
    while (i > 1) {
        i -= 1;
        nodes[nodes[i].parent].size += nodes[i].size;
        nodes[nodes[i].parent].files += nodes[i].files;
    }
    return tree;
}

/// Windows: the volume of `path` ("C:\Users\ada") read through its MFT, as
/// administrator; error.NotNtfs (and others) to scan folder by folder instead.
pub fn readVolume(alloc: Allocator, io: Io, path: []const u8, options: Options) Error!scan.Tree {
    if (builtin.os.tag != .windows) return error.NotNtfs;
    if (path.len < 3 or path[1] != ':') return error.NotNtfs;
    var device: [7:0]u16 = .{ '\\', '\\', '.', '\\', path[0], ':', 0 };
    const handle = CreateFileW(&device, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.ReadFailed;
    const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, path[3..], "\\/");
    while (it.next()) |part| try parts.append(alloc, part);
    return read(alloc, .{ .file = file, .io = io }, path, parts.items, options);
}

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 1;
const FILE_SHARE_WRITE: u32 = 2;
const OPEN_EXISTING: u32 = 3;
extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?*anyopaque,
) callconv(.winapi) std.os.windows.HANDLE;

// ---- Tests: a real NTFS image (made by mkntfs and ntfs-3g) ----

const testing = std.testing;

fn find(tree: *const scan.Tree, parent: u32, name: []const u8) ?u32 {
    const node = tree.node(parent);
    for (tree.children(parent), 0..) |_, i| {
        const index = node.first_child + @as(u32, @intCast(i));
        if (std.mem.eql(u8, tree.name(index), name)) return index;
    }
    return null;
}

fn openFixture(a: Allocator, io: Io, tmp: *testing.TmpDir) !Io.File {
    const gz = try Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/ntfs.img.gz", a, .limited(8 << 20));
    defer a.free(gz);
    var in: Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "ntfs.img", .data = out.written() });
    return tmp.dir.openFile(io, "ntfs.img", .{});
}

test "an NTFS image through its MFT: folders, sizes, a hard link counted once" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = openFixture(a, io, &tmp) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // run from elsewhere than the project
        else => return err,
    };
    defer file.close(io);

    var tree = try read(a, .{ .file = file, .io = io }, "X:\\", &.{}, .{});
    defer tree.deinit(a);

    const projects = find(&tree, 0, "projects").?;
    const engine = find(&tree, projects, "engine").?;
    const photos = find(&tree, 0, "photos").?;
    const build_bin = find(&tree, engine, "build.bin").?;
    const same = find(&tree, photos, "same-build.bin").?;
    const trip = find(&tree, photos, "trip.jpg").?;
    const notes = find(&tree, projects, "notes.txt").?;
    try testing.expect(find(&tree, 0, "empty") != null);
    // NTFS's own files are there too ($MFT, ...), the root's self-link is not.
    try testing.expect(find(&tree, 0, "$MFT") != null);
    try testing.expect(find(&tree, 0, ".") == null);

    // 300,000 bytes in 4 KB clusters; its second name takes nothing.
    const cluster = 4096;
    const rounded = (300_000 + cluster - 1) / cluster * cluster;
    try testing.expectEqual(@as(u64, rounded), tree.node(build_bin).size + tree.node(same).size);
    try testing.expect(tree.node(build_bin).size == 0 or tree.node(same).size == 0);
    try testing.expectEqual(@as(u64, (120_000 + cluster - 1) / cluster * cluster), tree.node(trip).size);
    // A tiny file lives in its MFT record: nothing more on the disk.
    try testing.expectEqual(@as(u64, 0), tree.node(notes).size);
    // Files: the hard-linked one once (build, same-build: 1), trip, thumb, notes.
    try testing.expectEqual(@as(u64, 4), tree.node(projects).files + tree.node(photos).files);
    // Modification times from $STANDARD_INFORMATION (the image was made after 2020).
    try testing.expect(tree.node(trip).mtime > 1_577_836_800);
    try testing.expect(tree.node(notes).mtime > 1_577_836_800);

    // A folder inside, by its names.
    var inner = try read(a, .{ .file = file, .io = io }, "X:\\projects", &.{"PROJECTS"}, .{});
    defer inner.deinit(a);
    try testing.expect(find(&inner, 0, "engine") != null);
    try testing.expectError(error.NotFound, read(a, .{ .file = file, .io = io }, "X:\\nope", &.{"nope"}, .{}));
}

test "fixups and run lists" {
    // A run list: 0x21 = 1 length byte, 2 offset bytes: 0x18 clusters at
    // 0x5634; then 0x11: 0x02 clusters at -0x10 from it; then a sparse run.
    var bytes: [0x60]u8 = @splat(0);
    bytes[8] = 1; // non-resident
    std.mem.writeInt(u16, bytes[0x20..0x22], 0x48, .little);
    const list = [_]u8{ 0x21, 0x18, 0x34, 0x56, 0x11, 0x02, 0xF0, 0x01, 0x05, 0x00 };
    @memcpy(bytes[0x48..][0..list.len], &list);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(testing.allocator);
    try (Attribute{ .kind = AT_DATA, .bytes = &bytes }).runs(testing.allocator, &runs);
    try testing.expectEqual(@as(usize, 3), runs.items.len);
    try testing.expectEqual(@as(u64, 0x5634), runs.items[0].lcn);
    try testing.expectEqual(@as(u64, 0x18), runs.items[0].clusters);
    try testing.expectEqual(@as(u64, 0x5624), runs.items[1].lcn);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), runs.items[2].lcn);

    // A record's sector ends restored from its update sequence array.
    var record: [1024]u8 = @splat(0);
    @memcpy(record[0..4], "FILE");
    std.mem.writeInt(u16, record[4..6], 0x30, .little);
    std.mem.writeInt(u16, record[6..8], 3, .little);
    std.mem.writeInt(u16, record[0x30..0x32], 0xABCD, .little); // the sequence number
    std.mem.writeInt(u16, record[0x32..0x34], 0x1111, .little); // sector 1's real end
    std.mem.writeInt(u16, record[0x34..0x36], 0x2222, .little);
    std.mem.writeInt(u16, record[510..512], 0xABCD, .little);
    std.mem.writeInt(u16, record[1022..1024], 0xABCD, .little);
    try testing.expect(fixup(&record, 512));
    try testing.expectEqual(@as(u16, 0x1111), std.mem.readInt(u16, record[510..512], .little));
    try testing.expectEqual(@as(u16, 0x2222), std.mem.readInt(u16, record[1022..1024], .little));
    // Torn (a sector's end not the sequence number): not a record.
    std.mem.writeInt(u16, record[510..512], 0x0000, .little);
    std.mem.writeInt(u16, record[1022..1024], 0xABCD, .little);
    try testing.expect(!fixup(&record, 512));
}
