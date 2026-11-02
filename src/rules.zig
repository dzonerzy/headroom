//! What can go: the caches and build output developers' tools make and make
//! again, found in a scanned tree, each with what it is, how safe it is to
//! clear, and how (deleted by Headroom, a tool's own command, the Recycle
//! Bin emptied, or only shown).
//!
//! A rule matches a folder by its name and where it is (a file beside it,
//! one inside it, the folders above it), a file by its name and where it
//! is, or a folder by a marker file in it (CMakeCache.txt). A folder matched
//! is not looked into: one node_modules, not the ones inside it.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
/// The scanner these rules read (tools/scan.zig scans with it).
pub const scanner = scan;

pub const Risk = enum {
    /// Made again without anyone noticing (caches).
    safe,
    /// Made again by a command or the next build, which takes time.
    rebuild,
    /// Holds something that is not simply made again: read what it is first.
    careful,
};

pub const Action = enum {
    /// Headroom deletes it (it comes back by itself or by `command`).
    delete,
    /// Its tool clears it: `command`, copied for the user to run.
    command,
    /// The Recycle Bin (Windows) or the Trash (Linux), emptied.
    empty_bin,
    /// Only shown: what to do is in `why`.
    show,
};

pub const Os = enum { any, windows, linux };

pub const Kind = enum { folder, file, marker };

pub const Rule = struct {
    id: []const u8,
    title: []const u8,
    why: []const u8,
    risk: Risk,
    action: Action,
    /// The command that clears it (or brings it back, for `delete`).
    command: ?[]const u8 = null,
    kind: Kind = .folder,
    /// The folder's or file's name; for `marker`, the marker file's.
    name: []const u8,
    /// A file that must be beside it (in the same folder).
    beside: ?[]const u8 = null,
    /// A file that must be in it.
    inside: ?[]const u8 = null,
    /// The folders it must be in, nearest last ("*": any name).
    under: []const []const u8 = &.{},
    os: Os = .any,
};

pub const rules = [_]Rule{
    // ---- Projects ----
    .{ .id = "node_modules", .title = "npm packages (node_modules)", .why = "Installed again from package.json by npm install (or yarn, pnpm).", .risk = .rebuild, .action = .delete, .command = "npm install", .name = "node_modules", .beside = "package.json" },
    .{ .id = "cargo-target", .title = "Rust build output (target)", .why = "Built again by cargo build.", .risk = .rebuild, .action = .delete, .command = "cargo clean", .name = "target", .beside = "Cargo.toml" },
    .{ .id = "zig-cache", .title = "Zig build caches (.zig-cache)", .why = "Zig's build cache: the next zig build fills it again.", .risk = .safe, .action = .delete, .name = ".zig-cache" },
    .{ .id = "zig-cache-old", .title = "Zig build caches (zig-cache)", .why = "Zig's build cache (before 0.13): the next zig build fills it again.", .risk = .safe, .action = .delete, .name = "zig-cache" },
    .{ .id = "zig-out", .title = "Zig build output (zig-out)", .why = "What zig build installs: built again by the next zig build.", .risk = .rebuild, .action = .delete, .command = "zig build", .name = "zig-out", .beside = "build.zig" },
    .{ .id = "cmake", .title = "CMake build trees", .why = "Folders CMake built into (they hold CMakeCache.txt): configured and built again from the sources.", .risk = .rebuild, .action = .delete, .kind = .marker, .name = "CMakeCache.txt" },
    .{ .id = "pycache", .title = "Python bytecode (__pycache__)", .why = "Compiled again by Python when the modules are imported.", .risk = .safe, .action = .delete, .name = "__pycache__" },
    .{ .id = "py-tools", .title = "Python tool caches", .why = "pytest, mypy and ruff fill them again on their next run.", .risk = .safe, .action = .delete, .name = ".pytest_cache" },
    .{ .id = "py-tools", .title = "Python tool caches", .why = "pytest, mypy and ruff fill them again on their next run.", .risk = .safe, .action = .delete, .name = ".mypy_cache" },
    .{ .id = "py-tools", .title = "Python tool caches", .why = "pytest, mypy and ruff fill them again on their next run.", .risk = .safe, .action = .delete, .name = ".ruff_cache" },
    .{ .id = "venv", .title = "Python virtual environments", .why = "Made again with python -m venv and the project's requirements; anything installed by hand in one is lost.", .risk = .careful, .action = .delete, .kind = .marker, .name = "pyvenv.cfg" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".next", .beside = "package.json" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".nuxt", .beside = "package.json" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".svelte-kit", .beside = "package.json" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".parcel-cache", .beside = "package.json" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".turbo", .beside = "package.json" },
    .{ .id = "web-build", .title = "Web framework build caches", .why = "Next.js, Nuxt, SvelteKit, Parcel, Turborepo and Angular build them again.", .risk = .safe, .action = .delete, .name = ".angular", .beside = "package.json" },

    // ---- Package managers' caches ----
    .{ .id = "zig-global", .title = "Zig's global cache", .why = "Packages and compiled pieces Zig keeps for every project: fetched and built again as needed.", .risk = .safe, .action = .delete, .name = "zig", .under = &.{ "AppData", "Local" }, .os = .windows },
    .{ .id = "zig-global", .title = "Zig's global cache", .why = "Packages and compiled pieces Zig keeps for every project: fetched and built again as needed.", .risk = .safe, .action = .delete, .name = "zig", .under = &.{".cache"}, .os = .linux },
    .{ .id = "npm-cache", .title = "npm's download cache", .why = "Packages npm downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "npm cache clean --force", .name = "npm-cache", .under = &.{ "AppData", "Local" }, .os = .windows },
    .{ .id = "npm-cache", .title = "npm's download cache", .why = "Packages npm downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "npm cache clean --force", .name = "_cacache", .under = &.{".npm"}, .os = .linux },
    .{ .id = "yarn-cache", .title = "Yarn's cache", .why = "Packages Yarn downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "yarn cache clean", .name = "Cache", .under = &.{ "Local", "Yarn" }, .os = .windows },
    .{ .id = "yarn-cache", .title = "Yarn's cache", .why = "Packages Yarn downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "yarn cache clean", .name = "yarn", .under = &.{".cache"}, .os = .linux },
    .{ .id = "pnpm-store", .title = "pnpm's store", .why = "Packages shared by pnpm projects; prune keeps those still used.", .risk = .safe, .action = .command, .command = "pnpm store prune", .name = "store", .under = &.{ "Local", "pnpm" }, .os = .windows },
    .{ .id = "pnpm-store", .title = "pnpm's store", .why = "Packages shared by pnpm projects; prune keeps those still used.", .risk = .safe, .action = .command, .command = "pnpm store prune", .name = "pnpm", .under = &.{ ".local", "share" }, .os = .linux },
    .{ .id = "pip-cache", .title = "pip's cache", .why = "Packages pip downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "pip cache purge", .name = "Cache", .under = &.{ "Local", "pip" }, .os = .windows },
    .{ .id = "pip-cache", .title = "pip's cache", .why = "Packages pip downloaded once; fetched again when needed.", .risk = .safe, .action = .command, .command = "pip cache purge", .name = "pip", .under = &.{".cache"}, .os = .linux },
    .{ .id = "cargo-registry", .title = "Cargo's registry cache", .why = "Crates Cargo downloaded; fetched again by the next build that needs them.", .risk = .safe, .action = .delete, .name = "registry", .under = &.{".cargo"} },
    .{ .id = "go-mod", .title = "Go's module cache", .why = "Modules Go downloaded (read-only files: Go's own command clears them).", .risk = .safe, .action = .command, .command = "go clean -modcache", .name = "mod", .under = &.{ "go", "pkg" } },
    .{ .id = "gradle", .title = "Gradle's caches", .why = "Dependencies and builds Gradle keeps; fetched and made again.", .risk = .safe, .action = .delete, .name = "caches", .under = &.{".gradle"} },
    .{ .id = "maven", .title = "Maven's repository", .why = "Dependencies Maven downloaded; fetched again by the next build.", .risk = .safe, .action = .delete, .name = "repository", .under = &.{".m2"} },
    .{ .id = "nuget", .title = "NuGet's packages", .why = "Packages .NET restored; restored again by dotnet restore.", .risk = .safe, .action = .command, .command = "dotnet nuget locals all --clear", .name = "packages", .under = &.{".nuget"} },

    // ---- Virtual disks: their tools ----
    .{ .id = "docker-disk", .title = "Docker Desktop's disk", .why = "Every image, container and volume of Docker Desktop. Prune what is unused (it removes stopped containers and unused images); the disk file shrinks once Docker compacts it.", .risk = .careful, .action = .command, .command = "docker system prune --all", .kind = .file, .name = "docker_data.vhdx", .os = .windows },
    .{ .id = "wsl-disk", .title = "WSL distributions' disks", .why = "A Linux distribution's whole disk. Clean inside it, then let it give the space back with wsl --manage <distribution> --set-sparse true.", .risk = .careful, .action = .show, .command = "wsl --manage <distribution> --set-sparse true", .kind = .file, .name = "ext4.vhdx", .os = .windows },
    .{ .id = "docker-linux", .title = "Docker's data", .why = "Every image, container and volume. Prune what is unused (stopped containers, unused images).", .risk = .careful, .action = .command, .command = "docker system prune --all", .name = "docker", .under = &.{ "var", "lib" }, .os = .linux },

    // ---- The system's ----
    .{ .id = "recycle-bin", .title = "The Recycle Bin", .why = "What was deleted to the Recycle Bin still takes its space until it is emptied.", .risk = .careful, .action = .empty_bin, .name = "$Recycle.Bin", .os = .windows },
    .{ .id = "trash", .title = "The Trash", .why = "What was moved to the Trash still takes its space until it is emptied.", .risk = .careful, .action = .empty_bin, .name = "Trash", .under = &.{ ".local", "share" }, .os = .linux },
    .{ .id = "temp", .title = "Temporary files", .why = "Programs leave files here. Close them, then delete what is inside (Disk Cleanup does it too).", .risk = .safe, .action = .show, .command = "cleanmgr", .name = "Temp", .under = &.{ "AppData", "Local" }, .os = .windows },
    .{ .id = "shaders", .title = "GPU shader caches", .why = "Shaders compiled for your GPU: games and apps compile them again (the first runs are slower).", .risk = .safe, .action = .delete, .name = "DXCache", .under = &.{"NVIDIA"}, .os = .windows },
    .{ .id = "shaders", .title = "GPU shader caches", .why = "Shaders compiled for your GPU: games and apps compile them again (the first runs are slower).", .risk = .safe, .action = .delete, .name = "GLCache", .under = &.{"NVIDIA"}, .os = .windows },
    .{ .id = "shaders", .title = "GPU shader caches", .why = "Shaders compiled for your GPU: games and apps compile them again (the first runs are slower).", .risk = .safe, .action = .delete, .name = "D3DSCache", .under = &.{ "AppData", "Local" }, .os = .windows },
    .{ .id = "shaders", .title = "GPU shader caches", .why = "Shaders compiled for your GPU: games and apps compile them again (the first runs are slower).", .risk = .safe, .action = .delete, .name = "shadercache", .under = &.{"steamapps"} },
    .{ .id = "crash-dumps", .title = "Crash dumps", .why = "Memory dumps of programs that crashed, kept for debugging.", .risk = .safe, .action = .delete, .name = "CrashDumps", .under = &.{ "AppData", "Local" }, .os = .windows },
    .{ .id = "windows-old", .title = "The previous Windows", .why = "The Windows installed before an upgrade, kept to go back. Disk Cleanup removes it (Clean up system files, Previous Windows installation).", .risk = .careful, .action = .show, .command = "cleanmgr", .name = "Windows.old", .os = .windows },
    .{ .id = "android-images", .title = "Android emulator images", .why = "System images for the Android emulator: the SDK Manager installs them again.", .risk = .rebuild, .action = .delete, .name = "system-images", .under = &.{"Sdk"} },
    .{ .id = "thumbnails", .title = "Thumbnails", .why = "Pictures' thumbnails the file manager made: made again when needed.", .risk = .safe, .action = .delete, .name = "thumbnails", .under = &.{".cache"}, .os = .linux },
    .{ .id = "apt", .title = "Downloaded packages (apt)", .why = "Packages apt downloaded and installed already.", .risk = .safe, .action = .command, .command = "sudo apt clean", .name = "archives", .under = &.{ "cache", "apt" }, .os = .linux },
    .{ .id = "journal", .title = "The system journal", .why = "The system's logs: vacuum keeps the newest.", .risk = .safe, .action = .command, .command = "sudo journalctl --vacuum-size=200M", .name = "journal", .under = &.{ "var", "log" }, .os = .linux },
};

/// A rule matched in the tree.
pub const Find = struct { node: u32, rule: u16 };

/// The matches under `root`, in tree order. A folder matched is not looked into.
pub fn find(a: std.mem.Allocator, tree: *const scan.Tree, root: u32) error{OutOfMemory}![]Find {
    var out: std.ArrayList(Find) = .empty;
    errdefer out.deinit(a);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    try stack.append(a, root);
    while (stack.pop()) |dir| {
        const node = tree.node(dir);
        if (node.child_count == 0) continue;
        // A marker inside: the folder is the match.
        if (dir != root) if (markerIn(tree, dir)) |rule| {
            try out.append(a, .{ .node = dir, .rule = rule });
            continue;
        };
        for (tree.children(dir), 0..) |child, i| {
            const index = node.first_child + @as(u32, @intCast(i));
            if (child.size == 0 and child.kind != .directory) continue;
            if (match(tree, index)) |rule| {
                try out.append(a, .{ .node = index, .rule = rule });
                continue;
            }
            if (child.kind == .directory) try stack.append(a, index);
        }
    }
    return out.toOwnedSlice(a);
}

/// The rules by lowercase name (folders' and files'): millions of names are
/// looked up after a scan, each against the few rules of its name only.
const by_name = blk: {
    @setEvalBranchQuota(200_000);
    var names: [rules.len][]const u8 = undefined;
    var count = 0;
    for (rules) |rule| {
        if (rule.kind == .marker) continue;
        const lower = lowerComptime(rule.name);
        for (names[0..count]) |seen| {
            if (std.mem.eql(u8, seen, lower)) break;
        } else {
            names[count] = lower;
            count += 1;
        }
    }
    var pairs: [count]struct { []const u8, []const u16 } = undefined;
    for (names[0..count], 0..) |name, p| {
        var indices: []const u16 = &.{};
        for (rules, 0..) |rule, r| {
            if (rule.kind != .marker and std.mem.eql(u8, lowerComptime(rule.name), name)) indices = indices ++ [_]u16{r};
        }
        pairs[p] = .{ name, indices };
    }
    break :blk std.StaticStringMap([]const u16).initComptime(pairs);
};

fn lowerComptime(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
        const final = out;
        return &final;
    }
}

const longest_name = blk: {
    var n = 0;
    for (rules) |rule| n = @max(n, rule.name.len);
    break :blk n;
};

/// The rule `index` (a folder or a file) matches by name and place.
fn match(tree: *const scan.Tree, index: u32) ?u16 {
    const n = tree.node(index);
    const name = tree.name(index);
    if (name.len > longest_name) return null;
    var buffer: [longest_name]u8 = undefined;
    const candidates = by_name.get(std.ascii.lowerString(&buffer, name)) orelse return null;
    for (candidates) |r| {
        const rule = rules[r];
        if (!forThisOs(rule.os)) continue;
        switch (rule.kind) {
            .marker => continue,
            .folder => if (n.kind != .directory) continue,
            .file => if (n.kind != .file) continue,
        }
        if (!sameName(name, rule.name)) continue;
        if (rule.beside) |file| if (!hasChild(tree, n.parent, file)) continue;
        if (rule.inside) |file| if (!hasChild(tree, index, file)) continue;
        if (!isUnder(tree, index, rule.under)) continue;
        return r;
    }
    return null;
}

fn markerIn(tree: *const scan.Tree, dir: u32) ?u16 {
    for (rules, 0..) |rule, r| {
        if (rule.kind != .marker or !forThisOs(rule.os)) continue;
        if (hasChild(tree, dir, rule.name)) return @intCast(r);
    }
    return null;
}

fn forThisOs(os: Os) bool {
    return switch (os) {
        .any => true,
        .windows => builtin.os.tag == .windows,
        .linux => builtin.os.tag == .linux,
    };
}

/// Names compared as the system does: without case on Windows.
fn sameName(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn hasChild(tree: *const scan.Tree, dir: u32, name: []const u8) bool {
    const node = tree.node(dir);
    for (tree.children(dir), 0..) |_, i| {
        if (sameName(tree.name(node.first_child + @as(u32, @intCast(i))), name)) return true;
    }
    return false;
}

/// Whether the folders above `index` end with `chain` (nearest last). Above
/// the scanned folder, its own path goes on: scanning AppData\Local, a zig
/// in it is under "AppData", "Local".
fn isUnder(tree: *const scan.Tree, index: u32, chain: []const []const u8) bool {
    var at = tree.node(index).parent;
    var i = chain.len;
    while (i > 0 and at != 0) {
        i -= 1;
        if (!componentIs(tree.name(at), chain[i])) return false;
        at = tree.node(at).parent;
    }
    // The rest against the scanned folder's path, from its end.
    var path = std.mem.trimEnd(u8, tree.root, "/\\");
    while (i > 0) {
        i -= 1;
        if (path.len == 0) return false;
        if (!componentIs(std.fs.path.basename(path), chain[i])) return false;
        path = std.fs.path.dirname(path) orelse "";
    }
    return true;
}

fn componentIs(name: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, want, "*") or sameName(name, want);
}

// ---- Tests ----

const testing = std.testing;
const testtree = @import("testtree.zig");

fn ruleOf(tree: *const scan.Tree, finds: []const Find, name: []const u8) ?[]const u8 {
    for (finds) |f| if (std.mem.eql(u8, tree.name(f.node), name)) return rules[f.rule].id;
    return null;
}

test "projects: node_modules once, target beside Cargo.toml, a CMake tree" {
    const a = testing.allocator;
    var tree = try testtree.make(a, "/home/ada", &.{
        .{ 0, "web", .directory, 0 }, // 1
        .{ 0, "rusty", .directory, 0 }, // 2
        .{ 0, "notes", .directory, 0 }, // 3
        .{ 0, "engine", .directory, 0 }, // 4
        .{ 1, "package.json", .file, 1_000 }, // 5
        .{ 1, "node_modules", .directory, 0 }, // 6
        .{ 2, "Cargo.toml", .file, 500 }, // 7
        .{ 2, "target", .directory, 0 }, // 8
        .{ 3, "target", .directory, 0 }, // 9: no Cargo.toml beside: not Rust's
        .{ 4, "build", .directory, 0 }, // 10
        .{ 6, "left-pad", .directory, 0 }, // 11
        .{ 8, "debug.bin", .file, 9_000_000 }, // 12
        .{ 9, "draft.txt", .file, 4_000 }, // 13
        .{ 10, "CMakeCache.txt", .file, 30_000 }, // 14
        .{ 11, "node_modules", .directory, 0 }, // 15: inside one already
        .{ 11, "index.js", .file, 2_000 }, // 16
        .{ 15, "deep.js", .file, 7_000 }, // 17
    });
    defer tree.deinit(a);
    const finds = try find(a, &tree, 0);
    defer a.free(finds);
    try testing.expectEqual(@as(usize, 3), finds.len);
    try testing.expectEqualStrings("node_modules", ruleOf(&tree, finds, "node_modules").?);
    try testing.expectEqualStrings("cargo-target", ruleOf(&tree, finds, "target").?);
    try testing.expectEqualStrings("cmake", ruleOf(&tree, finds, "build").?);
    for (finds) |f| try testing.expect(f.node != 9 and f.node != 15);
    // The node_modules found holds the nested one's size.
    for (finds) |f| if (f.node == 6) try testing.expectEqual(@as(u64, 9_000), tree.node(6).size);
}

test "caches by place" {
    const a = testing.allocator;
    if (builtin.os.tag == .windows) {
        var tree = try testtree.make(a, "C:\\Users\\ada", &.{
            .{ 0, "AppData", .directory, 0 }, // 1
            .{ 1, "Local", .directory, 0 }, // 2
            .{ 2, "pip", .directory, 0 }, // 3
            .{ 2, "zig", .directory, 0 }, // 4
            .{ 2, "Cache", .directory, 0 }, // 5: not under pip
            .{ 3, "Cache", .directory, 0 }, // 6
            .{ 4, "o", .directory, 0 }, // 7
            .{ 5, "x.bin", .file, 10 }, // 8
            .{ 6, "wheel.whl", .file, 1_000 }, // 9
            .{ 7, "lib.a", .file, 5_000 }, // 10
        });
        defer tree.deinit(a);
        const finds = try find(a, &tree, 0);
        defer a.free(finds);
        try testing.expectEqual(@as(usize, 2), finds.len);
        try testing.expectEqualStrings("zig-global", ruleOf(&tree, finds, "zig").?);
        for (finds) |f| if (f.node == 6) try testing.expectEqualStrings("pip-cache", rules[f.rule].id);
    } else {
        var tree = try testtree.make(a, "/home/ada", &.{
            .{ 0, ".cache", .directory, 0 }, // 1
            .{ 1, "pip", .directory, 0 }, // 2
            .{ 1, "zig", .directory, 0 }, // 3
            .{ 2, "http", .file, 1_000 }, // 4
            .{ 3, "o", .file, 5_000 }, // 5
        });
        defer tree.deinit(a);
        const finds = try find(a, &tree, 0);
        defer a.free(finds);
        try testing.expectEqual(@as(usize, 2), finds.len);
        try testing.expectEqualStrings("pip-cache", ruleOf(&tree, finds, "pip").?);
        try testing.expectEqualStrings("zig-global", ruleOf(&tree, finds, "zig").?);
    }
}

test "the scanned folder's own name counts for places" {
    const a = testing.allocator;
    // Scanned: ~/.cache itself; pip is under ".cache".
    const root = if (builtin.os.tag == .windows) "C:\\Users\\ada\\AppData\\Local" else "/home/ada/.cache";
    const name = if (builtin.os.tag == .windows) "zig" else "pip";
    var tree = try testtree.make(a, root, &.{
        .{ 0, name, .directory, 0 },
        .{ 1, "blob", .file, 100 },
    });
    defer tree.deinit(a);
    const finds = try find(a, &tree, 0);
    defer a.free(finds);
    try testing.expectEqual(@as(usize, 1), finds.len);
}
