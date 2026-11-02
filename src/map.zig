//! The treemap drawn under the page by OpenGL ES 3 (Plume's native layer):
//! every rectangle of the layout in one instanced draw. Folders are frames
//! with a header strip, files cushions lit from the top left (van Wijk's
//! cushion treemaps: the nesting reads without borders), what is too small
//! a dotted tile. Opening a folder or going back up zooms, on the GPU.
//!
//! The page owns the rest: labels, the tooltip, the header. Its transparent
//! area over the map is `viewport`.

const std = @import("std");
const plume = @import("plume");
const treemap = @import("treemap.zig");
const categories = @import("categories.zig");
const gl = plume.gl;

/// One rectangle, as the GPU reads it.
pub const Instance = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]u8,
    /// Shape, depth, whether a folder has a header, unused.
    info: [4]u8,
};

pub const background = 0x0d141c;

/// Shared between the page's calls (main thread) and the draw (compositor
/// thread): under `lock`.
pub const Map = struct {
    window: ?*plume.Window,
    io: std.Io,
    lock: std.Io.Mutex = .init,
    instances: std.ArrayList(Instance) = .empty,
    version: u64 = 0,
    /// The map's area in the window, CSS pixels; the device pixel ratio.
    viewport: treemap.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scale: f32 = 1,
    hovered: i32 = -1,
    /// The zoom: what the layout is drawn as at its start (p * s + t),
    /// eased to where it is.
    zoom_from: [4]f32 = .{ 1, 1, 0, 0 },
    zoom_start: f64 = 0,
    zoom_pending: bool = false,
    /// The compositor thread's.
    gpu: ?Gpu = null,

    pub const zoom_ms = 320.0;

    const Gpu = struct {
        core: gl.Core,
        extra: Extra,
        program: gl.Uint,
        buffer: gl.Uint,
        array: gl.Uint,
        count: i32 = 0,
        version: u64 = 0,
        u_size: gl.Int,
        u_viewport: gl.Int,
        u_scale: gl.Int,
        u_transform: gl.Int,
        u_header: gl.Int,
        u_hovered: gl.Int,
    };

    const Extra = struct {
        glVertexAttribDivisor: *const fn (gl.Uint, gl.Uint) callconv(.c) void,
        glDrawArraysInstanced: *const fn (gl.Enum, gl.Int, gl.Sizei, gl.Sizei) callconv(.c) void,
        glScissor: *const fn (gl.Int, gl.Int, gl.Sizei, gl.Sizei) callconv(.c) void,
    };

    pub fn deinit(map: *Map, a: std.mem.Allocator) void {
        map.instances.deinit(a);
    }

    /// A new layout to draw; `zoom`: where it starts from (see zoomIn/zoomOut).
    pub fn show(map: *Map, a: std.mem.Allocator, layout: *const treemap.Layout, zoom: ?[4]f32) !void {
        map.lock.lockUncancelable(map.io);
        defer map.lock.unlock(map.io);
        map.instances.clearRetainingCapacity();
        try map.instances.ensureTotalCapacity(a, layout.items.items.len);
        for (layout.items.items) |item| map.instances.appendAssumeCapacity(instance(item));
        map.version += 1;
        map.hovered = -1;
        if (zoom) |from| {
            map.zoom_from = from;
            map.zoom_pending = true;
        }
        map.redraw();
    }

    pub fn setViewport(map: *Map, viewport: treemap.Rect, scale: f32) void {
        map.lock.lockUncancelable(map.io);
        defer map.lock.unlock(map.io);
        map.viewport = viewport;
        map.scale = scale;
        map.redraw();
    }

    pub fn hover(map: *Map, index: ?usize) void {
        map.lock.lockUncancelable(map.io);
        defer map.lock.unlock(map.io);
        const value: i32 = if (index) |i| @intCast(i) else -1;
        if (value == map.hovered) return;
        map.hovered = value;
        map.redraw();
    }

    pub fn clear(map: *Map) void {
        map.lock.lockUncancelable(map.io);
        defer map.lock.unlock(map.io);
        map.instances.clearRetainingCapacity();
        map.version += 1;
        map.redraw();
    }

    fn redraw(map: *Map) void {
        if (map.window) |window| window.invalidateLayer();
    }

    /// The layer: on the compositor thread, the window's GL context current.
    pub fn draw(map: *Map, frame: plume.LayerFrame) void {
        const g = map.prepare() orelse return;
        const c = g.core;
        c.glViewport(0, 0, @intCast(frame.width), @intCast(frame.height));
        const bg = rgb(background);
        c.glClearColor(bg[0], bg[1], bg[2], 1);
        c.glClear(gl.COLOR_BUFFER_BIT);

        map.lock.lockUncancelable(map.io);
        if (g.version != map.version) {
            c.glBindBuffer(gl.ARRAY_BUFFER, g.buffer);
            const bytes = std.mem.sliceAsBytes(map.instances.items);
            c.glBufferData(gl.ARRAY_BUFFER, @intCast(bytes.len), if (bytes.len > 0) bytes.ptr else null, gl.STATIC_DRAW);
            g.count = @intCast(map.instances.items.len);
            g.version = map.version;
        }
        if (map.zoom_pending) {
            map.zoom_start = frame.time_ms;
            map.zoom_pending = false;
        }
        const t = std.math.clamp((frame.time_ms - map.zoom_start) / zoom_ms, 0, 1);
        const zooming = t < 1;
        // Ease out (cubic): fast, then settling.
        const e: f32 = @floatCast(1 - std.math.pow(f64, 1 - t, 3));
        const from = map.zoom_from;
        const transform = [4]f32{
            from[0] + (1 - from[0]) * e,
            from[1] + (1 - from[1]) * e,
            from[2] * (1 - e),
            from[3] * (1 - e),
        };
        const viewport = map.viewport;
        const scale = map.scale;
        const hovered = if (zooming) -1 else map.hovered;
        map.lock.unlock(map.io);

        if (g.count == 0) return;
        const height: f32 = @floatFromInt(frame.height);
        c.glEnable(SCISSOR_TEST);
        g.extra.glScissor(
            @intFromFloat(viewport.x * scale),
            @intFromFloat(height - (viewport.y + viewport.h) * scale),
            @intFromFloat(viewport.w * scale),
            @intFromFloat(viewport.h * scale),
        );
        c.glUseProgram(g.program);
        c.glUniform2f(g.u_size, @floatFromInt(frame.width), height);
        c.glUniform4f(g.u_viewport, viewport.x, viewport.y, viewport.w, viewport.h);
        c.glUniform1f(g.u_scale, scale);
        c.glUniform4f(g.u_transform, transform[0], transform[1], transform[2], transform[3]);
        c.glUniform1f(g.u_header, (treemap.Options{}).header);
        c.glUniform1i(g.u_hovered, hovered);
        c.glBindVertexArray(g.array);
        g.extra.glDrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, g.count);
        c.glBindVertexArray(0);
        c.glDisable(SCISSOR_TEST);
        if (zooming) map.redraw();
    }

    fn prepare(map: *Map) ?*Gpu {
        if (map.gpu) |*g| return g;
        const core = gl.load(gl.Core) catch return null;
        const extra = gl.load(Extra) catch return null;
        const program = gl.program(core, vertex_source, fragment_source) orelse return null;
        var buffer: gl.Uint = 0;
        core.glGenBuffers(1, @ptrCast(&buffer));
        var array: gl.Uint = 0;
        core.glGenVertexArrays(1, @ptrCast(&array));
        core.glBindVertexArray(array);
        core.glBindBuffer(gl.ARRAY_BUFFER, buffer);
        const stride = @sizeOf(Instance);
        core.glEnableVertexAttribArray(0);
        core.glVertexAttribPointer(0, 4, gl.FLOAT, 0, stride, @ptrFromInt(@offsetOf(Instance, "x")));
        core.glEnableVertexAttribArray(1);
        core.glVertexAttribPointer(1, 4, gl.UNSIGNED_BYTE, 1, stride, @ptrFromInt(@offsetOf(Instance, "color")));
        core.glEnableVertexAttribArray(2);
        core.glVertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, 0, stride, @ptrFromInt(@offsetOf(Instance, "info")));
        for (0..3) |i| extra.glVertexAttribDivisor(@intCast(i), 1);
        core.glBindVertexArray(0);
        map.gpu = .{
            .core = core,
            .extra = extra,
            .program = program,
            .buffer = buffer,
            .array = array,
            .u_size = core.glGetUniformLocation(program, "size"),
            .u_viewport = core.glGetUniformLocation(program, "viewport"),
            .u_scale = core.glGetUniformLocation(program, "scale"),
            .u_transform = core.glGetUniformLocation(program, "transform"),
            .u_header = core.glGetUniformLocation(program, "header"),
            .u_hovered = core.glGetUniformLocation(program, "hovered"),
        };
        return &map.gpu.?;
    }
};

const SCISSOR_TEST: gl.Enum = 0x0C11;

/// Where a layout starts when `rect` (where the opened folder was) grows to
/// fill `bounds`: the new layout drawn shrunk into it.
pub fn zoomIn(rect: treemap.Rect, bounds: treemap.Rect) [4]f32 {
    const sx = rect.w / bounds.w;
    const sy = rect.h / bounds.h;
    return .{ sx, sy, rect.x - bounds.x * sx, rect.y - bounds.y * sy };
}

/// Where a layout starts when going back up: `rect` (where the folder left
/// is in it) drawn filling `bounds`, then shrinking into place.
pub fn zoomOut(rect: treemap.Rect, bounds: treemap.Rect) [4]f32 {
    const sx = bounds.w / rect.w;
    const sy = bounds.h / rect.h;
    return .{ sx, sy, bounds.x - rect.x * sx, bounds.y - rect.y * sy };
}

fn instance(item: treemap.Item) Instance {
    const color: u24 = switch (item.shape) {
        // Deeper frames a little lighter: the nesting reads.
        .folder => mix(0x16202b, 0x34465b, @min(@as(f32, @floatFromInt(item.depth)) * 0.13, 1)),
        .closed => 0x45566b,
        .file => categories.info.get(item.category).color,
        .rest => 0x5a6779,
    };
    return .{
        .x = item.rect.x,
        .y = item.rect.y,
        .w = item.rect.w,
        .h = item.rect.h,
        .color = .{ @truncate(color >> 16), @truncate(color >> 8), @truncate(color), 255 },
        .info = .{ @intFromEnum(item.shape), item.depth, @intFromBool(item.header), 0 },
    };
}

fn mix(a: u24, b: u24, t: f32) u24 {
    var out: u24 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const x: f32 = @floatFromInt((a >> shift) & 0xff);
        const y: f32 = @floatFromInt((b >> shift) & 0xff);
        out |= @as(u24, @intFromFloat(x + (y - x) * t)) << shift;
    }
    return out;
}

fn rgb(color: u24) [3]f32 {
    return .{
        @as(f32, @floatFromInt(color >> 16)) / 255,
        @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(color & 0xff)) / 255,
    };
}

/// A unit quad per instance (triangle strip), placed in the map and zoomed.
const vertex_source =
    \\#version 300 es
    \\layout(location = 0) in vec4 rect;
    \\layout(location = 1) in vec4 color;
    \\layout(location = 2) in vec4 info;
    \\uniform vec2 size;
    \\uniform vec4 viewport;
    \\uniform float scale;
    \\uniform vec4 transform;
    \\uniform int hovered;
    \\out vec2 local;
    \\flat out vec2 dims;
    \\flat out vec4 tint;
    \\flat out vec4 kind;
    \\flat out float lit;
    \\void main() {
    \\  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1));
    \\  vec2 p = (rect.xy + corner * rect.zw) * transform.xy + transform.zw;
    \\  vec2 px = (viewport.xy + p) * scale;
    \\  dims = rect.zw * transform.xy * scale;
    \\  local = corner * dims;
    \\  tint = color;
    \\  kind = info;
    \\  lit = gl_InstanceID == hovered ? 1.0 : 0.0;
    \\  gl_Position = vec4(px.x / size.x * 2.0 - 1.0, 1.0 - px.y / size.y * 2.0, 0.0, 1.0);
    \\}
;

/// Frames, cushions, dotted rests; a light rim on what is under the mouse.
const fragment_source =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 local;
    \\flat in vec2 dims;
    \\flat in vec4 tint;
    \\flat in vec4 kind;
    \\flat in float lit;
    \\uniform float scale;
    \\uniform float header;
    \\out vec4 color;
    \\void main() {
    \\  float shape = kind.x;
    \\  float edge = min(min(local.x, dims.x - local.x), min(local.y, dims.y - local.y));
    \\  vec3 c = tint.rgb;
    \\  if (shape < 0.5) {
    \\    // A folder: its body, a header strip lit from above, a dark rim.
    \\    float hh = header * scale;
    \\    if (kind.z > 0.5 && local.y < hh) {
    \\      c = mix(c, vec3(0.62, 0.72, 0.84), 0.16 + 0.10 * (1.0 - local.y / hh));
    \\    }
    \\    if (edge < scale) c *= 0.55;
    \\  } else {
    \\    vec2 uv = local / max(dims, vec2(1.0));
    \\    vec2 q = uv * 2.0 - 1.0;
    \\    if (shape < 2.5) {
    \\      // A cushion: a soft bump, lit from the top left.
    \\      float bump = (1.0 - 0.6 * q.x * q.x) * (1.0 - 0.6 * q.y * q.y);
    \\      float light = 0.42 + 0.62 * bump - 0.16 * (q.x * 0.5 + q.y * 0.85);
    \\      c = c * light;
    \\      if (shape > 0.5 && shape < 1.5) c = mix(c, vec3(0.05, 0.08, 0.11), 0.15);
    \\    } else {
    \\      // The rest: dots, like grain too fine to tell apart.
    \\      vec2 d = mod(gl_FragCoord.xy, 3.0 * scale);
    \\      float dot = step(d.x, scale) * step(d.y, scale);
    \\      c = c * (0.38 + 0.42 * dot);
    \\    }
    \\    if (edge < 0.75 * scale) c *= 0.32;
    \\  }
    \\  if (lit > 0.5) {
    \\    c = edge < 2.0 * scale ? mix(c, vec3(0.97, 0.98, 1.0), 0.9) : mix(c, vec3(1.0), 0.10);
    \\  }
    \\  color = vec4(c, 1.0);
    \\}
;
