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

    // The scanner alone: its unit tests, and a run on a real folder.
    const scan = b.createModule(.{ .root_source_file = b.path("src/scan.zig"), .target = target, .optimize = optimize });
    const scan_tests = b.addTest(.{ .root_module = scan });
    b.step("test-scan", "Run the scanner's unit tests").dependOn(&b.addRunArtifact(scan_tests).step);
    const scan_tool = b.addExecutable(.{ .name = "scan", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/scan.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "scan", .module = scan }},
    }) });
    const scan_run = b.addRunArtifact(scan_tool);
    scan_run.addPassthruArgs();
    b.step("scan", "Scan a folder: zig build scan -- <folder> [threads]").dependOn(&scan_run.step);
}
