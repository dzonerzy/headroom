//! UI tests: the app runs headless (no window, no display, no GL layer: the
//! map's labels and the bindings are what is checked), its page driven with
//! real input on a clock the test controls. `plume test` runs them, and the
//! scanner's, the layout's and the categories' own tests.

const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;
const Map = @import("map.zig").Map;
const scan = @import("scan.zig");

test {
    _ = @import("scan.zig");
    _ = @import("treemap.zig");
    _ = @import("categories.zig");
    _ = @import("volume.zig");
    _ = @import("elevate.zig");
    _ = @import("remove.zig");
    _ = @import("app.zig");
    _ = @import("rules.zig");
    _ = @import("snapshot.zig");
    _ = @import("disks.zig");
    _ = @import("ntfs.zig");
    _ = @import("projects.zig");
    _ = @import("wsl.zig");
    _ = @import("docker.zig");
    _ = @import("dupes.zig");
    _ = @import("history.zig");
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

/// With HEADROOM_SHOTS set to a folder: the page as drawn, <name>.png in it
/// (headless: the map's GL layer is not in it).
fn shot(h: *plume.testing.Harness, name: []const u8) !void {
    // The process's own environment: the build's is cached with its configuration.
    const folder = std.testing.environ.getAlloc(std.testing.allocator, "HEADROOM_SHOTS") catch return;
    defer std.testing.allocator.free(folder);
    const png = try h.capturePng();
    var buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/{s}.png", .{ folder, name });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = png });
}

test "what can go: found, listed, deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "web/package.json", 2_000);
    try write(tmp.dir, "web/node_modules/react/index.js", 600_000);
    try write(tmp.dir, "web/node_modules/vite/bin.js", 300_000);
    try write(tmp.dir, "tool/__pycache__/main.pyc", 90_000);
    try write(tmp.dir, "photos/trip.jpg", 400_000);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    try h.click(".stage .control-main");
    try h.waitFor(".control-reclaim");
    try std.testing.expect(std.mem.endsWith(u8, try h.text(".control-reclaim"), "can go"));
    try h.click(".control-reclaim");
    try h.waitFor(".reclaim");
    // node_modules (the biggest), then the bytecode; the photo is not listed.
    try h.expectText(".reclaim-group:first-child .reclaim-title", "npm packages (node_modules)");
    try std.testing.expectEqual(@as(u32, 2), try h.evaluate(u32, "document.querySelectorAll('.reclaim-group').length"));
    try shot(h, "reclaim");

    // Delete it, for good: gone from the disk, the list and the map.
    try h.click(".reclaim-group:first-child .reclaim-do");
    try h.waitFor(".dialog");
    try h.click(".control-danger");
    try h.waitUntil("document.querySelector('.veil') === null");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "web/node_modules", .{}));
    try tmp.dir.access(std.testing.io, "web/package.json", .{});
    try h.waitUntil("document.querySelectorAll('.reclaim-group').length === 1");
    try h.waitUntil("document.querySelector('.notice')?.textContent.startsWith('Deleted 1 place') === true");
}

test "old projects: the untouched one listed and cleared, the recent one not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // shop: untouched for 200 days, its node_modules rebuilt lately (not a
    // touch); blog: written today.
    try write(tmp.dir, "shop/package.json", 2_000);
    try write(tmp.dir, "shop/src/app.js", 30_000);
    try write(tmp.dir, "shop/node_modules/react/index.js", 600_000);
    try write(tmp.dir, "blog/package.json", 2_000);
    try write(tmp.dir, "blog/node_modules/vite/bin.js", 300_000);
    const io = std.testing.io;
    const long_ago = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000) - 200 * 24 * 3600;
    try scan.setMtime(tmp.dir, io, "shop/package.json", long_ago);
    try scan.setMtime(tmp.dir, io, "shop/src/app.js", long_ago);
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    try h.click(".stage .control-main");
    try h.waitFor(".control-stale");
    try std.testing.expect(std.mem.endsWith(u8, try h.text(".control-stale"), "in old projects"));
    try h.click(".control-stale");
    try h.waitFor(".stale-project");
    try std.testing.expectEqual(@as(u32, 1), try h.evaluate(u32, "document.querySelectorAll('.stale-project').length"));
    try h.expectText(".stale-project .reclaim-title", "shop");
    try std.testing.expect(std.mem.indexOf(u8, try h.text(".stale-project .reclaim-why"), "months ago") != null);
    try shot(h, "stale");

    // A year: shop is not that old.
    try h.click(".stale-age:nth-of-type(3)");
    try h.waitUntil("document.querySelectorAll('.stale-project').length === 0");
    try h.click(".stale-age:nth-of-type(1)");
    try h.waitFor(".stale-project");

    // Cleared, for good: its node_modules gone, its code kept.
    try h.click(".stale-project .reclaim-do");
    try h.waitFor(".dialog");
    try h.click(".control-danger");
    try h.waitUntil("document.querySelector('.veil') === null");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "shop/node_modules", .{}));
    try tmp.dir.access(io, "shop/src/app.js", .{});
    try tmp.dir.access(io, "blog/node_modules/vite/bin.js", .{});
    try h.waitUntil("document.querySelectorAll('.stale-project').length === 0");
}

test "duplicates: found, one copy removed, the other kept" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const mb = 1 << 20;
    // The same 2 MB twice, and a same-size file with other bytes.
    try write(tmp.dir, "downloads/movie.mkv", 2 * mb);
    try write(tmp.dir, "backup/movie.mkv", 2 * mb);
    {
        var data: [64]u8 = undefined;
        @memset(&data, 'y');
        try write(tmp.dir, "other/movie.mkv", 2 * mb);
        var file = try tmp.dir.openFile(io, "other/movie.mkv", .{ .mode = .read_write });
        defer file.close(io);
        try file.writePositionalAll(io, &data, 0);
    }
    try scan.setMtime(tmp.dir, io, "downloads/movie.mkv", 1_600_000_000); // the older: kept
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    try h.click(".stage .control-main");
    try h.waitUntil("document.querySelector('.status')?.textContent.includes('entries scanned') === true");
    try h.click(".control-machine");
    try h.waitFor(".side-tabs");
    try h.evaluate(void, "[...document.querySelectorAll('.side-tab')].find(t => t.textContent === 'Duplicates').click()");
    try h.click(".dupes-find");
    try h.waitFor(".dupes-group");
    try std.testing.expectEqual(@as(u32, 1), try h.evaluate(u32, "document.querySelectorAll('.dupes-group').length"));
    try std.testing.expectEqual(@as(u32, 2), try h.evaluate(u32, "document.querySelectorAll('.dupes-copy').length"));
    // The older copy stays, the other is checked.
    try std.testing.expectEqual(@as(u32, 1), try h.evaluate(u32, "document.querySelectorAll('.dupes-copy input:checked').length"));
    try shot(h, "dupes");

    try h.click(".stale-all .reclaim-do");
    try h.waitFor(".dialog");
    try h.click(".control-danger");
    try h.waitUntil("document.querySelector('.veil') === null");
    try tmp.dir.access(io, "downloads/movie.mkv", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "backup/movie.mkv", .{}));
    try tmp.dir.access(io, "other/movie.mkv", .{});
    try h.waitUntil("document.querySelectorAll('.dupes-group').length === 0");
}

test "WSL & Docker: the tab, Docker asked once it opens" {
    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    // Before any scan, from the deck.
    try h.click(".control-machine");
    try h.waitFor(".machine-section");
    // No Docker here (the tests do not ask the machine's): it says so.
    try h.waitUntil("document.querySelector('.reclaim')?.textContent.includes('Docker is not installed') === true");
    try std.testing.expectEqual(@as(u32, 0), try h.evaluate(u32, "document.querySelectorAll('.machine-docker').length"));
    try shot(h, "machine");
}

test "what changed since the last scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "scanned/stays/notes.md", 10_000);
    try tmp.dir.createDirPath(std.testing.io, "data");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "scanned", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const data = try tmp.dir.realPathFileAlloc(std.testing.io, "data", std.testing.allocator);
    defer std.testing.allocator.free(data);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .data_dir = data, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    // The first scan: nothing to compare with.
    try h.click(".stage .control-main");
    try h.waitUntil("document.querySelector('.status')?.textContent.includes('entries scanned') === true");
    try std.testing.expect((try state.changed(h.arena.allocator())) == null);

    // A folder grows by 80 MB; the next scan says so, where.
    try write(tmp.dir, "scanned/downloads/game.zip", 80 * 1024 * 1024);
    try h.click(".control-rescan");
    try h.waitFor(".control-changed");
    try std.testing.expect(std.mem.startsWith(u8, try h.text(".control-changed"), "+80"));
    try h.click(".control-changed");
    try h.waitFor(".changes-entry");
    try h.expectText(".changes-entry .reclaim-path", "downloads");
    try h.expectText(".changes-detail", "new");
}

test "finding by name, and the list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "big/engine.zig", 400_000);
    try write(tmp.dir, "big/deep/engine-notes.md", 50_000);
    try write(tmp.dir, "other/photo.png", 300_000);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .width = 1200, .height = 780 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();
    try h.click(".stage .control-main");
    try h.waitFor(".search-field");

    // Two entries hold "ENGINE" (any case), the biggest first; Enter goes there.
    try h.typeText(".search-field", "ENGINE");
    try h.waitUntil("document.querySelectorAll('.search-result').length === 2");
    try h.expectText(".search-result:first-child .search-name", "engine.zig");
    try h.press("Enter", .{});
    try h.waitUntil("document.querySelector('.crumb[aria-current]')?.textContent === 'big'");

    // The list: what big holds, biggest first; a folder opens.
    try h.click(".viewswitch-option:nth-child(2)");
    try h.waitFor(".listing-row");
    try h.expectText(".listing-row .listing-name", "engine.zig");
    try h.evaluate(void, "[...document.querySelectorAll('.listing-row')].find((r) => r.querySelector('.listing-name').textContent === 'deep').click()");
    try h.waitUntil("document.querySelector('.crumb[aria-current]')?.textContent === 'deep'");
}

test "the tray's popover" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // In a folder with a name (the popover says "Largest in ada"): the
    // README's picture is this test's.
    try write(tmp.dir, "ada/games/big.pak", 900_000);
    try write(tmp.dir, "ada/photos/trip.jpg", 400_000);
    try write(tmp.dir, "ada/notes.md", 60_000);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "ada", std.testing.allocator);
    defer std.testing.allocator.free(root);
    // Two weeks of the disk's free space, an hour apart: 30 GB more free
    // than now two weeks ago, 12 GB more this morning.
    try tmp.dir.createDirPath(std.testing.io, "data");
    const data = try tmp.dir.realPathFileAlloc(std.testing.io, "data", std.testing.allocator);
    defer std.testing.allocator.free(data);
    {
        const disk = if (@import("builtin").os.tag == .windows) root[0..3] else "/";
        const space = @import("volume.zig").space(std.testing.allocator, disk).?;
        const now = @divFloor(std.Io.Clock.real.now(std.testing.io).toMilliseconds(), 1000);
        // As the page counts them.
        const GB: u64 = 1 << 30;
        var samples: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer samples.deinit();
        // From an hour inside the two weeks kept (not on its edge).
        var hours: u64 = 14 * 24 - 1;
        while (hours > 0) : (hours -= 1) {
            const more = if (hours <= 24) 12 * GB else 12 * GB + 18 * GB * (hours - 24) / (14 * 24 - 25);
            try samples.writer.print("{s}\t{d}\t{d}\t{d}\n", .{ disk, now - @as(i64, @intCast(hours)) * 3600, space.free + more, space.total });
        }
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data/space.tsv", .data = samples.written() });
    }

    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{ .page = "tray.html", .width = 340, .height = 580 });
    defer h.stop();
    var map: Map = .{ .window = null, .io = std.testing.io };
    defer map.deinit(std.heap.smp_allocator);
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .data_dir = data, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    // A scan done before: its largest entries are listed.
    _ = try state.scan(h.arena.allocator(), root);
    try h.open();

    try h.waitFor(".popover");
    try std.testing.expect((try h.text(".popover-figure .figure-value")).len > 0);
    try std.testing.expect(std.mem.startsWith(u8, try h.text(".popover-caption"), "headroom, "));
    // The arc: 40 segments, the used share lit once its sweep is done (on
    // the page's own clock: waited for). The share is the real disk's: a
    // nearly empty one (CI's) lights none.
    try std.testing.expectEqual(@as(u32, 40), try h.evaluate(u32, "document.querySelectorAll('.arc-segment').length"));
    try h.waitUntil("(a => a.dataset.lit === a.dataset.level)(document.querySelector('.arc'))");
    try std.testing.expect(try h.evaluate(bool, "document.querySelectorAll('.arc-segment[data-on]').length === Number(document.querySelector('.arc').dataset.level)"));
    try h.expectText(".popover-entry:first-child .popover-name", "games");
    try std.testing.expectEqual(@as(u32, 3), try h.evaluate(u32, "document.querySelectorAll('.popover-entry').length"));
    // The two weeks under the arc (the samples, then now), and the 12 GB
    // lost today (the disk's own
    // use may move it a little meanwhile).
    try h.waitFor(".popover-trend[data-fell]");
    try std.testing.expectEqual(@as(u32, 336), try h.evaluate(u32, "document.querySelector('.trend-line').points.length"));
    try std.testing.expect(std.mem.startsWith(u8, try h.text(".popover-trend-lost"), "−12"));
    try h.expectText(".popover-trend-caption span:first-child", "Free space, last 14 days");
    try shot(h, "popover");

    // The alarm's threshold: 20%.
    try h.click(".popover-choice:nth-child(4)");
    try h.waitUntil("document.querySelector('.popover-choice[aria-checked=true]')?.textContent === '20%'");
    try std.testing.expectEqual(@as(u8, 20), state.alarm());
    // The label and the choices on one line; the warning (the disk below
    // the alarm) on its own line above them, not beside them.
    try std.testing.expect(try h.evaluate(bool,
        \\(() => {
        \\  const label = document.querySelector('.popover-alarm-label').getBoundingClientRect();
        \\  const choices = document.querySelector('.popover-choices').getBoundingClientRect();
        \\  const warning = document.querySelector('.popover-warning')?.getBoundingClientRect();
        \\  const oneLine = Math.abs((label.top + label.bottom) - (choices.top + choices.bottom)) < 4 && label.right <= choices.left;
        \\  return oneLine && (!warning || warning.bottom <= Math.min(label.top, choices.top));
        \\})()
    ));
    try shot(h, "popover-alarm");
}

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
    var state: App = .{ .io = std.testing.io, .home_path = root, .map = &map, .mft = false, .docker = false };
    defer state.deinit();
    state.events = h.app.events(App.Events);
    try h.app.bind("App", App, &state);
    try h.open();

    // Watching free space needs a tray: headless there is none, and the
    // page says so.
    try h.click(".control-watch");
    try h.waitUntil("document.querySelector('.notice')?.textContent.startsWith('This desktop has no tray') === true");
    try std.testing.expect(!state.watching());

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

    // The meter follows the mouse: the file's share of the disk glows, named.
    try h.clickAt(file.x, file.y);
    try h.waitFor(".scale-focus");
    const caption = try h.text(".scale-focus");
    try std.testing.expect(std.mem.startsWith(u8, caption, "engine.zig is "));
    try std.testing.expect(std.mem.endsWith(u8, caption, " of the disk"));
    try std.testing.expect(try h.evaluate(u32, "document.querySelectorAll('.segment[data-state=focus]').length") >= 1);
    try shot(h, "meter");

    // Deleting for good (the Recycle Bin is the user's: not in a test):
    // Shift+Delete on photo.png asks, in red; the red button deletes it,
    // from the disk and from the map, without a new scan.
    const photo = try h.evaluate(Point,
        \\(() => {
        \\  const tile = [...document.querySelectorAll('.label-tile')]
        \\    .find((l) => l.querySelector('.label-name').textContent === 'photo.png');
        \\  const r = tile.getBoundingClientRect();
        \\  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
        \\})()
    );
    try h.clickAt(photo.x, photo.y);
    try h.press("Delete", .{ .shift = true });
    try h.waitFor(".dialog[data-mode=permanent]");
    try h.expectText(".dialog-title", "Delete photo.png permanently?");
    try shot(h, "delete");
    try h.click(".control-danger");
    try h.waitUntil("document.querySelector('.veil') === null");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "big/photo.png", .{}));
    try h.waitUntil("document.querySelector('.notice')?.textContent.startsWith('Deleted photo.png') === true");
    try std.testing.expect(!try h.evaluate(bool, "[...document.querySelectorAll('.label-name')].some((l) => l.textContent === 'photo.png')"));

    // What Headroom does not delete: the folder scanned.
    const scanned = try state.removal(h.arena.allocator(), 0);
    try std.testing.expect(scanned.refused != null);

    // Escape: back up.
    try h.press("Escape", .{});
    try h.waitUntil("document.querySelector('.crumb[aria-current]')?.textContent !== 'big'");
    try h.expectText(".crumb[aria-current]", root);
}
