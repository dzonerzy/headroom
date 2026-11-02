const std = @import("std");
const plume = @import("plume");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = plume.default_target });
    const optimize = b.standardOptimizeOption(.{});

    // src/main.zig with the engine, plume.json and the built frontend;
    // frontend/src/bindings.ts generated from src/app.zig's App.
    const app = plume.addApp(b, .{ .name = "headroom", .target = target, .optimize = optimize }) orelse return;
    b.installArtifact(app.executable);

    const run = b.addRunArtifact(app.executable);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the application").dependOn(&run.step);
    b.step("bindings", "Write frontend/src/bindings.ts").dependOn(app.bindings);
}
