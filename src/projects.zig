//! Stale projects: folders of code nobody has touched for a while that
//! still hold what their tools make again (node_modules, target, build
//! trees). Clearing those is the space a developer will not miss.
//!
//! A project is a folder with a project file (package.json, Cargo.toml,
//! build.zig, *.csproj, ...). It was last touched when its newest file was
//! written, not counting what is made again, its .git, nor the projects
//! inside it. What can go is the rules' finds that come back by themselves
//! or with a build and that Headroom deletes.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
const rules = @import("rules.zig");

pub const Project = struct {
    node: u32,
    /// Seconds since 1970; 0 when no file had a time.
    last_touched: i64,
    /// What can go in it, in bytes.
    size: u64,
    /// The finds to clear (tree nodes), largest first.
    finds: []const u32,
};

/// The project files a folder is recognized by ("*.ext": any name ending so).
const markers = [_][]const u8{
    "package.json",  "Cargo.toml",   "build.zig",     "CMakeLists.txt", "pyproject.toml",
    "setup.py",      "go.mod",       "pom.xml",       "build.gradle",   "build.gradle.kts",
    "composer.json", "Gemfile",      "mix.exs",       "pubspec.yaml",   "vcpkg.json",
    "project.godot", "*.csproj",     "*.fsproj",      "*.vbproj",       "*.sln",
    "*.uproject",    "ProjectSettings",
};

/// The projects under `root` whose files were all written before `cutoff`
/// (seconds since 1970) and that have something to clear, largest first.
/// Slices in `a` (an arena: nothing is freed one by one).
pub fn stale(a: std.mem.Allocator, tree: *const scan.Tree, root: u32, finds: []const rules.Find, cutoff: i64) error{OutOfMemory}![]Project {
    const n = tree.nodes.items.len;
    // Which nodes are finds that can go, by rule.
    const clearable = try std.DynamicBitSetUnmanaged.initEmpty(a, n);
    var clear = clearable;
    for (finds) |f| {
        const rule = rules.rules[f.rule];
        if (rule.action == .delete and rule.risk != .careful and f.node < n) clear.set(f.node);
    }

    const Open = struct { node: u32, newest: i64 = 0, size: u64 = 0, finds: std.ArrayList(u32) = .empty };
    var open: std.ArrayList(Open) = .empty;
    var done: std.ArrayList(Open) = .empty;
    // Depth first; a project's frame closes once its subtree is walked.
    const Visit = struct { node: u32, project: ?usize, leave: bool = false };
    var stack: std.ArrayList(Visit) = .empty;
    try stack.append(a, .{ .node = root, .project = null });
    while (stack.pop()) |visit| {
        if (visit.leave) {
            try done.append(a, open.items[visit.project.?]);
            continue;
        }
        const node = tree.node(visit.node);
        var project = visit.project;
        if (node.kind == .directory and isProject(tree, visit.node)) {
            try open.append(a, .{ .node = visit.node });
            project = open.items.len - 1;
            try stack.append(a, .{ .node = visit.node, .project = project, .leave = true });
        }
        for (0..node.child_count) |i| {
            const child: u32 = node.first_child + @as(u32, @intCast(i));
            const c = tree.node(child);
            if (clear.isSet(child)) {
                // Made again: counted to clear, not as a touch, not walked
                // (a find deleted already has no size left).
                if (project) |p| if (c.size > 0) {
                    open.items[p].size += c.size;
                    try open.items[p].finds.append(a, child);
                };
                continue;
            }
            switch (c.kind) {
                .file => if (project) |p| {
                    open.items[p].newest = @max(open.items[p].newest, c.mtime);
                },
                .directory => if (!sameName(tree.name(child), ".git")) try stack.append(a, .{ .node = child, .project = project }),
                else => {},
            }
        }
    }

    var found: std.ArrayList(Project) = .empty;
    for (done.items) |p| {
        if (p.finds.items.len == 0 or p.newest == 0 or p.newest >= cutoff) continue;
        const list = p.finds.items;
        std.mem.sort(u32, list, tree, struct {
            fn larger(t: *const scan.Tree, x: u32, y: u32) bool {
                return t.node(x).size > t.node(y).size;
            }
        }.larger);
        try found.append(a, .{ .node = p.node, .last_touched = p.newest, .size = p.size, .finds = list });
    }
    std.mem.sort(Project, found.items, {}, struct {
        fn larger(_: void, x: Project, y: Project) bool {
            return x.size > y.size;
        }
    }.larger);
    return found.items;
}

fn isProject(tree: *const scan.Tree, dir: u32) bool {
    const node = tree.node(dir);
    for (0..node.child_count) |i| {
        const name = tree.name(node.first_child + @as(u32, @intCast(i)));
        for (markers) |m| {
            if (m[0] == '*') {
                const end = m[1..];
                if (name.len > end.len and sameName(name[name.len - end.len ..], end)) return true;
            } else if (sameName(name, m)) return true;
        }
    }
    return false;
}

fn sameName(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

// ---- Tests ----

const testing = std.testing;
const testtree = @import("testtree.zig");

const day = 24 * 3600;
const now: i64 = 1_760_000_000; // 2025-10-09
const old = now - 200 * day;
const recent = now - 3 * day;

test "an old project with node_modules is stale, a recent one is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try testtree.makeTimed(testing.allocator, "/home/ada", &.{
        .{ 0, "shop", .directory, 0, recent }, // 1: old project
        .{ 0, "blog", .directory, 0, recent }, // 2: recent project
        .{ 0, "notes", .directory, 0, old }, // 3: not a project
        .{ 1, "package.json", .file, 1_000, old }, // 4
        .{ 1, "node_modules", .directory, 0, recent }, // 5: rebuilt lately: not a touch
        .{ 1, ".git", .directory, 0, recent }, // 6: a fetch lately: not a touch
        .{ 2, "package.json", .file, 1_000, old }, // 7
        .{ 2, "index.md", .file, 1_000, recent }, // 8: written lately
        .{ 2, "node_modules", .directory, 0, old }, // 9
        .{ 3, "todo.txt", .file, 1_000, old }, // 10
        .{ 5, "react.js", .file, 400_000, recent }, // 11
        .{ 6, "HEAD", .file, 10, recent }, // 12
        .{ 9, "vue.js", .file, 300_000, old }, // 13
    });
    defer tree.deinit(testing.allocator);
    const finds = try rules.find(a, &tree, 0);
    const found = try stale(a, &tree, 0, finds, now - 90 * day);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].node);
    try testing.expectEqual(@as(i64, old), found[0].last_touched);
    try testing.expectEqual(@as(u64, 400_000), found[0].size);
    try testing.expectEqualSlices(u32, &.{5}, found[0].finds);
}

test "a project inside another is its own; careful finds are not cleared" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try testtree.makeTimed(testing.allocator, "/home/ada", &.{
        .{ 0, "mono", .directory, 0, old }, // 1: a workspace
        .{ 1, "Cargo.toml", .file, 500, old }, // 2
        .{ 1, "target", .directory, 0, old }, // 3
        .{ 1, "web", .directory, 0, old }, // 4: a project inside
        .{ 1, "venv", .directory, 0, old }, // 5: careful (pyvenv.cfg)
        .{ 3, "app.exe", .file, 9_000_000, old }, // 6
        .{ 4, "package.json", .file, 1_000, recent }, // 7: touched lately
        .{ 4, "node_modules", .directory, 0, old }, // 8
        .{ 5, "pyvenv.cfg", .file, 100, old }, // 9
        .{ 5, "big.whl", .file, 5_000_000, old }, // 10
        .{ 8, "lib.js", .file, 70_000, old }, // 11
    });
    defer tree.deinit(testing.allocator);
    const finds = try rules.find(a, &tree, 0);
    const found = try stale(a, &tree, 0, finds, now - 90 * day);
    // mono is stale (its target); web inside it is not (touched); the venv stays.
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].node);
    try testing.expectEqualSlices(u32, &.{3}, found[0].finds);
    try testing.expectEqual(@as(u64, 9_000_000), found[0].size);
}

test "a .NET project by its *.csproj; largest first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try testtree.makeTimed(testing.allocator, "/home/ada", &.{
        .{ 0, "small", .directory, 0, old }, // 1
        .{ 0, "big", .directory, 0, old }, // 2
        .{ 1, "Cargo.toml", .file, 500, old }, // 3
        .{ 1, "target", .directory, 0, old }, // 4
        .{ 2, "Api.csproj", .file, 500, old }, // 5
        .{ 2, "bin", .directory, 0, old }, // 6
        .{ 2, "obj", .directory, 0, old }, // 7
        .{ 4, "a", .file, 1_000, old }, // 8
        .{ 6, "Api.dll", .file, 50_000, old }, // 9
        .{ 7, "Api.pdb", .file, 70_000, old }, // 10
    });
    defer tree.deinit(testing.allocator);
    const finds = try rules.find(a, &tree, 0);
    const found = try stale(a, &tree, 0, finds, now - 90 * day);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(u32, 2), found[0].node);
    try testing.expectEqual(@as(u64, 120_000), found[0].size);
    // Its finds largest first: obj, then bin.
    try testing.expectEqualSlices(u32, &.{ 7, 6 }, found[0].finds);
}
