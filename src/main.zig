const std = @import("std");
const builtin = @import("builtin");
const plume = @import("plume");
const App = @import("app.zig").App;
const Map = @import("map.zig").Map;

pub fn main(init: std.process.Init) !void {
    // The window of plume.json (a native layer under its page), showing the
    // frontend (built into the binary, or Vite's dev server under plume dev).
    const app = try plume.App.initProject(@import("plume_project"), init);
    defer app.deinit();

    // The treemap, drawn by GL under the page.
    var map: Map = .{ .window = app.window(), .io = init.io };
    defer map.deinit(std.heap.smp_allocator);
    app.window().setLayer(&map, Map.draw) catch {
        map.window = null;
    };

    const home = init.environ_map.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "";
    var state: App = .{ .io = init.io, .home_path = home, .map = &map };
    defer state.deinit();
    state.events = app.events(App.Events);
    try app.bind("App", App, &state);

    app.run();
}
