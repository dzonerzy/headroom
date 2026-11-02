//! UI tests: the app runs headless (no window, no display, no GL layer: the
//! map's labels and the bindings are what is checked), its page driven with
//! real input on a clock the test controls. `plume test` runs them, and the
//! scanner's, the layout's and the categories' own tests.

const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;
const Map = @import("map.zig").Map;

test {
    _ = @import("scan.zig");
    _ = @import("treemap.zig");
    _ = @import("categories.zig");
    _ = @import("volume.zig");
    _ = @import("elevate.zig");
}

fn write(dir: std.Io.Dir, path: []const u8, bytes: usize) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const data = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

const Point = struct { x: f32, y: f32 };

test "scanning a folder, opening one of its folders, going back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "big/engine.zig", 400_000);
    try write(tmp.dir, "big/photo.png", 300_000);
    try write(tmp.dir, "big/deeper/notes.md", 120_000);
    try write(tmp.dir, "archive.zip", 250_000);
    try write(tmp.dir, "small/readme.txt", 90_000);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1100, .height = 760 });
    defer h.stop();
    // As main.zig does, without the layer (headless).
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    // The start: one button scans the home folder.
    try h.expectText(".stage-title", "See what fills your disk");
    try h.click(".stage .control-main");
    try h.waitFor(".label-header");
    try h.expectText(".crumb[aria-current]", root);
    try h.waitUntil("document.querySelector('.status')?.textContent.includes('entries scanned')");

    // The legend has what the folder holds, biggest first.
    try h.expectText(".legend-entry:first-child .legend-name", "Source code");

    // big/ is a frame with its name in its header: a click there opens it.
    const big = try h.evaluate(Point,
        \\(() => {
        \\  const header = [...document.querySelectorAll('.label-header')]
        \\    .find((l) => l.querySelector('.label-name').textContent === 'big');
        \\  const r = header.getBoundingClientRect();
        \\  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        \\})()
    );
    try h.clickAt(big.x, big.y);
    try h.waitUntil("document.querySelector('.crumb[aria-current]')?.textContent === 'big'");
    // Its labels come back once the zoom is over.
    h.advance(600);
    try h.waitFor(".labels[data-shown]");
    try std.testing.expectEqual(@as(u32, 2), try h.evaluate(u32, "document.querySelectorAll('.crumb').length"));

    // What is under the mouse: the tooltip names it.
    const file = try h.evaluate(Point,
        \\(() => {
        \\  const tile = [...document.querySelectorAll('.label-tile')]
        \\    .find((l) => l.querySelector('.label-name').textContent === 'engine.zig');
        \\  const r = tile.getBoundingClientRect();
        \\  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        \\})()
    );
    const map_box = try h.evaluate(Point, "(() => { const r = document.querySelector('.map').getBoundingClientRect(); return { x: r.left, y: r.top }; })()");
    const item = (try state.hover(h.arena.allocator(), file.x - map_box.x, file.y - map_box.y)).?;
    try std.testing.expectEqualStrings("engine.zig", item.name);
    try std.testing.expectEqualStrings("Source code", item.category.?.name);

    // Escape: back up.
    try h.press("Escape", .{});
    try h.waitUntil("document.querySelector('.crumb[aria-current]')?.textContent !== 'big'");
    try h.expectText(".crumb[aria-current]", root);
}
