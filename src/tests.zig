//! UI tests: the app runs headless (no window, no display), its page driven
//! with real input on a clock the test controls. `plume test` builds the
//! frontend and runs them; `plume test --update-snapshots` rewrites the
//! snapshots (tests/snapshots/<os>/).

const std = @import("std");
const plume = @import("plume");
const App = @import("app.zig").App;

test "greeting someone" {
    const h = try plume.testing.Harness.startProject(@import("plume_project"), .{});
    defer h.stop();
    // As main.zig does.
    var state: App = .{ .events = h.app.events(App.Events) };
    try h.app.bind("App", App, &state);
    try h.open();

    try h.typeText("#name", "Ada");
    try h.click(".ask .action");
    try h.expectText(".answer", "Hello, Ada.");
    try std.testing.expectEqual(@as(u32, 1), state.greetings);

    // The answer as drawn, once its entrance animation is over (the page's
    // clock is the test's: advance it).
    h.advance(1500);
    try h.snapshotElement("answer", ".answer");
}
