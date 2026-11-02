const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    // The window of plume.json, showing the frontend (built into the binary,
    // or Vite's dev server under plume dev).
    const app = try plume.App.initProject(@import("plume_project"), init);
    defer app.deinit();

    // App's pub fns, callable from the frontend (frontend/src/bindings.ts),
    // and its events, which any thread can send.
    var state: App = .{ .events = app.events(App.Events) };
    try app.bind("App", App, &state);

    app.run();
}
