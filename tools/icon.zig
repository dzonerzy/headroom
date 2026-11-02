//! zig build icon: icon.png (1024 px), drawn the way the map draws: a folder
//! frame with its header strip, cushion tiles in the legend's colors, and
//! one slot left empty, outlined in the meter's green: the room you get back.

const std = @import("std");
const flate = std.compress.flate;

const size = 1024;
/// Samples per pixel along each axis: smooth edges.
const samples = 4;

const Rect = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

const night = [3]f32{ 0.051, 0.078, 0.110 };
const night_top = [3]f32{ 0.098, 0.141, 0.192 };
const frame = [3]f32{ 0.106, 0.149, 0.200 };
const header = [3]f32{ 0.200, 0.267, 0.345 };
const level = [3]f32{ 0.322, 0.780, 0.635 };

// The tile and what is in it (pixels of the 1024 canvas).
const tile: Rect = .{ .x0 = 72, .y0 = 72, .x1 = 952, .y1 = 952 };
const radius = 196;
const folder: Rect = .{ .x0 = 168, .y0 = 176, .x1 = 856, .y1 = 856 };
const header_height = 78;
const gap = 14;
const body: Rect = .{ .x0 = folder.x0 + 18, .y0 = folder.y0 + header_height, .x1 = folder.x1 - 18, .y1 = folder.y1 - 18 };
const split_x = body.x0 + (body.x1 - body.x0) * 0.5;
const split_y = body.y0 + (body.y1 - body.y0) * 0.46;
const split_x2 = split_x + (body.x1 - split_x) * 0.58;

const Tile = struct { rect: Rect, color: [3]f32 };
const tiles = [_]Tile{
    .{ .rect = .{ .x0 = body.x0, .y0 = body.y0, .x1 = split_x - gap / 2, .y1 = body.y1 }, .color = .{ 0.357, 0.553, 0.937 } },
    .{ .rect = .{ .x0 = split_x + gap / 2, .y0 = split_y + gap / 2, .x1 = split_x2 - gap / 2, .y1 = body.y1 }, .color = .{ 0.816, 0.541, 0.235 } },
    .{ .rect = .{ .x0 = split_x2 + gap / 2, .y0 = split_y + gap / 2, .x1 = body.x1, .y1 = body.y1 }, .color = .{ 0.608, 0.435, 0.863 } },
};
/// The headroom: room at the top.
const empty: Rect = .{ .x0 = split_x + gap / 2, .y0 = body.y0, .x1 = body.x1, .y1 = split_y - gap / 2 };

fn inside(r: Rect, x: f32, y: f32) bool {
    return x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1;
}

/// Distance outside a rounded rectangle (negative inside).
fn roundedDistance(r: Rect, corner: f32, x: f32, y: f32) f32 {
    const cx = (r.x0 + r.x1) / 2;
    const cy = (r.y0 + r.y1) / 2;
    const hx = (r.x1 - r.x0) / 2 - corner;
    const hy = (r.y1 - r.y0) / 2 - corner;
    const qx = @abs(x - cx) - hx;
    const qy = @abs(y - cy) - hy;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - corner;
}

fn mix(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

fn scale(c: [3]f32, k: f32) [3]f32 {
    return .{ c[0] * k, c[1] * k, c[2] * k };
}

/// A cushion, as src/map.zig's shader: a soft bump lit from the top left.
fn cushion(r: Rect, color: [3]f32, x: f32, y: f32) [3]f32 {
    const qx = (x - r.x0) / (r.x1 - r.x0) * 2 - 1;
    const qy = (y - r.y0) / (r.y1 - r.y0) * 2 - 1;
    const bump = (1 - 0.6 * qx * qx) * (1 - 0.6 * qy * qy);
    return scale(color, 0.42 + 0.62 * bump - 0.16 * (qx * 0.5 + qy * 0.85));
}

/// The color at (x, y) and its coverage (0 outside the tile).
fn sample(x: f32, y: f32) struct { c: [3]f32, a: f32 } {
    const outside = roundedDistance(tile, radius, x, y);
    if (outside > 0) return .{ .c = .{ 0, 0, 0 }, .a = 0 };
    // The tile: night, a little lighter at the top; a faint rim of light.
    var c = mix(night_top, night, std.math.clamp((y - tile.y0) / (tile.y1 - tile.y0), 0, 1));
    if (outside > -5) c = mix(c, .{ 0.25, 0.33, 0.42 }, 0.5);

    if (inside(folder, x, y)) {
        c = frame;
        if (y < folder.y0 + header_height) {
            // The header strip, lit from above.
            const t = (y - folder.y0) / header_height;
            c = mix(header, frame, t * 0.6);
        }
        const edge = @min(@min(x - folder.x0, folder.x1 - x), @min(y - folder.y0, folder.y1 - y));
        if (edge < 5) c = scale(c, 0.6);
    }
    for (tiles) |t| {
        if (inside(t.rect, x, y)) c = cushion(t.rect, t.color, x, y);
    }
    if (inside(empty, x, y)) {
        // Empty, dark; its outline the meter's green, glowing inward.
        const edge = @min(@min(x - empty.x0, empty.x1 - x), @min(y - empty.y0, empty.y1 - y));
        c = .{ 0.039, 0.063, 0.086 };
        if (edge < 12) {
            c = level;
        } else {
            // The glow falls off smoothly from a rounded inner edge (no seams
            // at the corners).
            const inner: Rect = .{ .x0 = empty.x0 + 12, .y0 = empty.y0 + 12, .x1 = empty.x1 - 12, .y1 = empty.y1 - 12 };
            const depth = -roundedDistance(inner, 40, x, y);
            const glow = @exp(-@max(depth, 0) / 30);
            c = mix(c, level, glow * 0.5);
        }
    }
    return .{ .c = c, .a = 1 };
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: icon <out.png>\n", .{});
        return 2;
    }
    const a = std.heap.smp_allocator;
    const rgba = try a.alloc(u8, size * size * 4);
    defer a.free(rgba);
    const n: f32 = samples * samples;
    for (0..size) |py| {
        for (0..size) |px| {
            var sum = [3]f32{ 0, 0, 0 };
            var cover: f32 = 0;
            for (0..samples) |sy| {
                for (0..samples) |sx| {
                    const x = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / samples;
                    const y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / samples;
                    const s = sample(x, y);
                    // Premultiplied while summed.
                    for (0..3) |i| sum[i] += s.c[i] * s.a;
                    cover += s.a;
                }
            }
            const o = rgba[(py * size + px) * 4 ..][0..4];
            const alpha = cover / n;
            for (0..3) |i| {
                const straight = if (cover > 0) sum[i] / cover else 0;
                o[i] = @intFromFloat(std.math.clamp(straight, 0, 1) * 255 + 0.5);
            }
            o[3] = @intFromFloat(alpha * 255 + 0.5);
        }
    }
    const png = try encode(a, rgba, size, size);
    defer a.free(png);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = png });
    return 0;
}

/// RGBA rows as a PNG (as Plume's src/png.zig).
fn encode(a: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    var compressed: std.Io.Writer.Allocating = try .initCapacity(a, 64 * 1024);
    defer compressed.deinit();
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const compressor = try a.create(flate.Compress);
    defer a.destroy(compressor);
    compressor.* = try flate.Compress.init(&compressed.writer, window, .zlib, .default);
    const row_len = @as(usize, width) * 4;
    for (0..height) |y| {
        try compressor.writer.writeByte(0);
        try compressor.writer.writeAll(rgba[y * row_len ..][0..row_len]);
    }
    try compressor.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var head: [13]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], width, .big);
    std.mem.writeInt(u32, head[4..8], height, .big);
    head[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(a, &out, "IHDR", &head);
    try chunk(a, &out, "IDAT", compressed.written());
    try chunk(a, &out, "IEND", "");
    return out.toOwnedSlice(a);
}

fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.appendSlice(a, &length);
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(a, &sum);
}
