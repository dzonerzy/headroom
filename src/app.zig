//! What the frontend can call. Every pub fn taking the App is a binding:
//! frontend/src/bindings.ts gets its exact TypeScript type at every build.

const std = @import("std");
const plume = @import("plume");

pub const App = struct {
    /// Methods that run on a worker thread and return a Promise.
    pub const async_methods = .{"countTo"};

    /// The events Zig sends the frontend (and the frontend Zig): their names
    /// and data, typed in bindings.ts too.
    pub const Events = struct {
        progress: Progress,
    };

    pub const Progress = struct { done: u32, total: u32 };

    pub const Greeting = struct { text: []const u8, number: u32 };

    greetings: u32 = 0,
    /// Set by main.zig: how any thread sends events to the frontend.
    events: ?plume.Events(Events) = null,

    /// An Allocator parameter gets the call's arena: nothing to free.
    pub fn greet(self: *App, allocator: std.mem.Allocator, name: []const u8) !Greeting {
        self.greetings += 1;
        const who = std.mem.trim(u8, name, " ");
        return .{
            .text = try std.fmt.allocPrint(allocator, "Hello, {s}.", .{if (who.len == 0) "stranger" else who}),
            .number = self.greetings,
        };
    }

    /// On a worker thread (it is in async_methods): counts to `total`, one
    /// "progress" event per step. A std.Io parameter gets the app's.
    pub fn countTo(self: *App, io: std.Io, total: u32) !u32 {
        for (1..total + 1) |done| {
            try std.Io.sleep(io, .fromMilliseconds(120), .awake);
            self.events.?.emit(.progress, .{ .done = @intCast(done), .total = total });
        }
        return total;
    }
};
