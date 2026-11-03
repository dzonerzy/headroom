//! Docker's disk, from its own command line: what images, containers, the
//! build cache and volumes take (docker system df), and the prunes that
//! give space back. Volumes are only shown: they hold data (databases,
//! uploads) that is not made again, so Headroom never removes them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Category = struct {
    size: u64 = 0,
    /// What a prune gives back (Docker's own estimate).
    reclaimable: u64 = 0,
    count: u32 = 0,
    /// In use by a container.
    active: u32 = 0,
};

pub const Image = struct { name: []const u8, size: u64, used: bool };
pub const Container = struct { name: []const u8, image: []const u8, size: u64, running: bool };
pub const Volume = struct { name: []const u8, size: u64, used: bool };

pub const Usage = struct {
    images: Category = .{},
    containers: Category = .{},
    volumes: Category = .{},
    build_cache: Category = .{},
    image_list: []const Image = &.{},
    container_list: []const Container = &.{},
    volume_list: []const Volume = &.{},
};

/// What a prune clears.
pub const Prune = enum {
    /// Stopped containers.
    containers,
    /// Images no container uses (not only dangling ones).
    images,
    build_cache,

    pub fn argv(p: Prune) []const []const u8 {
        return switch (p) {
            .containers => &.{ "docker", "container", "prune", "--force" },
            .images => &.{ "docker", "image", "prune", "--all", "--force" },
            .build_cache => &.{ "docker", "builder", "prune", "--all", "--force" },
        };
    }
};

pub const Error = error{
    /// No docker command.
    NoDocker,
    /// The command is there, the engine does not answer (Docker Desktop
    /// stopped, no permission on the socket).
    NotRunning,
    Failed,
    OutOfMemory,
};

/// Docker's disk use: the summary and the lists. Seconds: Docker counts.
pub fn usage(a: Allocator, io: Io) Error!Usage {
    const summary = try run(a, io, &.{ "docker", "system", "df", "--format", "{{json .}}" });
    const verbose = try run(a, io, &.{ "docker", "system", "df", "--verbose", "--format", "{{json .}}" });
    var result = try parseVerbose(a, verbose);
    try parseSummary(summary, &result);
    return result;
}

/// Runs the prune; what Docker says it reclaimed, in bytes.
pub fn prune(a: Allocator, io: Io, what: Prune) Error!u64 {
    const out = try run(a, io, what.argv());
    return reclaimed(out);
}

fn run(a: Allocator, io: Io, argv: []const []const u8) Error![]const u8 {
    const result = std.process.run(a, io, .{
        .argv = argv,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
        .stdout_limit = .limited(64 << 20),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.NoDocker,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            // "Cannot connect to the Docker daemon", "error during connect",
            // "permission denied": the engine is not there for us.
            return error.NotRunning;
        },
        else => return error.Failed,
    }
    return result.stdout;
}

/// The summary's lines ({"Type":"Images","Size":"4.587GB","Reclaimable":"4.2GB (92%)",...}).
pub fn parseSummary(text: []const u8, into: *Usage) Error!void {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const Line = struct { Type: []const u8 = "", TotalCount: []const u8 = "0", Active: []const u8 = "0", Size: []const u8 = "0B", Reclaimable: []const u8 = "0B" };
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const parsed = std.json.parseFromSliceLeaky(Line, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        const category: Category = .{
            .size = parseSize(parsed.Size),
            .reclaimable = parseSize(parsed.Reclaimable),
            .count = std.fmt.parseInt(u32, parsed.TotalCount, 10) catch 0,
            .active = std.fmt.parseInt(u32, parsed.Active, 10) catch 0,
        };
        if (std.mem.eql(u8, parsed.Type, "Images")) into.images = category;
        if (std.mem.eql(u8, parsed.Type, "Containers")) into.containers = category;
        if (std.mem.eql(u8, parsed.Type, "Local Volumes")) into.volumes = category;
        if (std.mem.eql(u8, parsed.Type, "Build Cache")) into.build_cache = category;
    }
}

/// The verbose output: one object with the Images, Containers and Volumes.
pub fn parseVerbose(a: Allocator, text: []const u8) Error!Usage {
    const Raw = struct {
        Images: []const struct { Repository: []const u8 = "", Tag: []const u8 = "", ID: []const u8 = "", Size: []const u8 = "0B", Containers: []const u8 = "0" } = &.{},
        Containers: []const struct { Names: []const u8 = "", Image: []const u8 = "", Size: []const u8 = "0B", State: []const u8 = "" } = &.{},
        Volumes: []const struct { Name: []const u8 = "", Size: []const u8 = "0B", Links: []const u8 = "0" } = &.{},
    };
    const trimmed = std.mem.trim(u8, text, " \r\n");
    const raw = std.json.parseFromSliceLeaky(Raw, a, trimmed, .{ .ignore_unknown_fields = true }) catch return error.Failed;
    const images = try a.alloc(Image, raw.Images.len);
    for (raw.Images, images) |i, *out| {
        const name = if (i.Repository.len == 0 or std.mem.eql(u8, i.Repository, "<none>"))
            i.ID[0..@min(i.ID.len, 19)]
        else
            try std.fmt.allocPrint(a, "{s}:{s}", .{ i.Repository, i.Tag });
        out.* = .{ .name = name, .size = parseSize(i.Size), .used = !std.mem.eql(u8, i.Containers, "0") };
    }
    const containers = try a.alloc(Container, raw.Containers.len);
    for (raw.Containers, containers) |c, *out| {
        out.* = .{ .name = c.Names, .image = c.Image, .size = parseSize(c.Size), .running = std.mem.eql(u8, c.State, "running") };
    }
    const volumes = try a.alloc(Volume, raw.Volumes.len);
    for (raw.Volumes, volumes) |v, *out| {
        out.* = .{ .name = v.Name, .size = parseSize(v.Size), .used = !std.mem.eql(u8, v.Links, "0") };
    }
    const bySize = struct {
        fn image(_: void, x: Image, y: Image) bool {
            return x.size > y.size;
        }
        fn volume(_: void, x: Volume, y: Volume) bool {
            return x.size > y.size;
        }
    };
    std.mem.sort(Image, images, {}, bySize.image);
    std.mem.sort(Volume, volumes, {}, bySize.volume);
    return .{ .image_list = images, .container_list = containers, .volume_list = volumes };
}

/// Docker's sizes ("2.66GB", "176.1kB", "34B", "4.2GB (92%)"): powers of
/// 1000, as Docker writes them.
pub fn parseSize(text: []const u8) u64 {
    const t = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len], " ");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) end += 1;
    const number = std.fmt.parseFloat(f64, t[0..end]) catch return 0;
    const unit = t[end..];
    const scale: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "B"))
        1
    else switch (std.ascii.toLower(unit[0])) {
        'k' => 1e3,
        'm' => 1e6,
        'g' => 1e9,
        't' => 1e12,
        'p' => 1e15,
        else => 1,
    };
    return @intFromFloat(@max(number * scale, 0));
}

/// "Total reclaimed space: 1.2GB" in a prune's output.
pub fn reclaimed(out: []const u8) u64 {
    const marker = "Total reclaimed space:";
    const at = std.mem.indexOf(u8, out, marker) orelse return 0;
    const rest = std.mem.trimStart(u8, out[at + marker.len ..], " ");
    return parseSize(rest[0 .. std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len]);
}

// ---- Tests: Docker's output as it writes it ----

const testing = std.testing;

test "sizes as Docker writes them" {
    try testing.expectEqual(@as(u64, 2_660_000_000), parseSize("2.66GB"));
    try testing.expectEqual(@as(u64, 176_100), parseSize("176.1kB"));
    try testing.expectEqual(@as(u64, 34), parseSize("34B"));
    try testing.expectEqual(@as(u64, 4_246_000_000), parseSize("4.246GB (92%)"));
    try testing.expectEqual(@as(u64, 0), parseSize("0B"));
    try testing.expectEqual(@as(u64, 0), parseSize(""));
    try testing.expectEqual(@as(u64, 1_200_000_000), reclaimed("Deleted Images:\nuntagged: x\n\nTotal reclaimed space: 1.2GB\n"));
}

test "the summary and the lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const verbose =
        \\{"Images":[{"Containers":"0","ID":"sha256:6f910869527e13b93186","Repository":"builder","Size":"2.66GB","Tag":"latest"},
        \\{"Containers":"1","ID":"sha256:d603","Repository":"web","Size":"341MB","Tag":"14.3.0"},
        \\{"Containers":"0","ID":"sha256:0123456789abcdef0123","Repository":"<none>","Size":"10MB","Tag":"<none>"}],
        \\"Containers":[{"Image":"web:14.3.0","Names":"web-1","Size":"176kB","State":"exited"}],
        \\"Volumes":[{"Links":"0","Name":"db","Size":"869.8MB"},{"Links":"1","Name":"uploads","Size":"88.5GB"}],
        \\"BuildCache":[]}
    ;
    var usage_ = try parseVerbose(arena.allocator(), verbose);
    try parseSummary(
        \\{"Active":"1","Reclaimable":"4.246GB (92%)","Size":"4.587GB","TotalCount":"5","Type":"Images"}
        \\{"Active":"0","Reclaimable":"176.1kB (100%)","Size":"176.1kB","TotalCount":"1","Type":"Containers"}
        \\{"Active":"1","Reclaimable":"88.51GB (99%)","Size":"88.51GB","TotalCount":"20","Type":"Local Volumes"}
        \\{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
    , &usage_);
    try testing.expectEqual(@as(u64, 4_246_000_000), usage_.images.reclaimable);
    try testing.expectEqual(@as(u32, 20), usage_.volumes.count);
    try testing.expectEqual(@as(u64, 0), usage_.build_cache.size);
    try testing.expectEqualStrings("builder:latest", usage_.image_list[0].name);
    try testing.expect(!usage_.image_list[0].used);
    try testing.expect(usage_.image_list[1].used);
    try testing.expectEqualStrings("sha256:0123456789ab", usage_.image_list[2].name);
    try testing.expect(!usage_.container_list[0].running);
    // Volumes largest first; in use or not, they are only shown.
    try testing.expectEqualStrings("uploads", usage_.volume_list[0].name);
    try testing.expect(usage_.volume_list[0].used);
}
