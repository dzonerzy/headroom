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

    const env = init.environ_map;
    const home = env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "";
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var state: App = .{
        .io = init.io,
        .home_path = home,
        .map = &map,
        // Restarted as administrator: the folder to scan again.
        .startup_scan = @import("elevate.zig").scanArgument(args),
        .plume_app = app,
        .settings_path = try settingsPath(init.arena.allocator(), env),
        .data_dir = try dataDir(init.arena.allocator(), env),
    };
    defer state.deinit();
    state.events = app.events(App.Events);
    try app.bind("App", App, &state);

    // Watching free space: the tray's menu, the window hiding to the tray,
    // the alarm's notification opening Headroom; on if it was last time.
    const Handlers = struct {
        fn menu(s: *App, id: []const u8) void {
            s.menuChosen(id);
        }
        fn close(s: *App) bool {
            return s.closing();
        }
        fn notification(s: *App, action: plume.NotificationAction) void {
            _ = action;
            s.menuChosen("open");
        }
    };
    try app.onMenu(&state, Handlers.menu);
    app.onClose(&state, Handlers.close);
    try app.onNotification(&state, Handlers.notification);
    if (state.settings_path) |path| {
        if (App.savedWatching(init.io, path)) state.startWatching() catch {};
    }

    app.run();
}

/// Where Headroom keeps what it measured (the snapshots): %LOCALAPPDATA%\
/// Headroom on Windows, $XDG_DATA_HOME/headroom (or ~/.local/share/headroom)
/// on Linux.
fn dataDir(a: std.mem.Allocator, env: *std.process.Environ.Map) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        const local = env.get("LOCALAPPDATA") orelse return null;
        return try std.fs.path.join(a, &.{ local, "Headroom" });
    }
    if (env.get("XDG_DATA_HOME")) |data| return try std.fs.path.join(a, &.{ data, "headroom" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(a, &.{ home, ".local", "share", "headroom" });
}

/// Headroom's settings: %APPDATA%\Headroom\settings.json on Windows,
/// $XDG_CONFIG_HOME/headroom (or ~/.config/headroom) on Linux.
fn settingsPath(a: std.mem.Allocator, env: *std.process.Environ.Map) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = env.get("APPDATA") orelse return null;
        return try std.fs.path.join(a, &.{ appdata, "Headroom", "settings.json" });
    }
    if (env.get("XDG_CONFIG_HOME")) |config| return try std.fs.path.join(a, &.{ config, "headroom", "settings.json" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(a, &.{ home, ".config", "headroom", "settings.json" });
}
