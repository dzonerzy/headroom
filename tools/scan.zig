//! zig build scan -Doptimize=ReleaseFast -- <folder> [threads]: the scanner
//! alone on a real folder, how long it takes, what is biggest in it, and
//! what the rules find that can go. "wsl:<distribution>" reads inside a WSL
//! distribution instead; "wsl:" alone lists them.

const std = @import("std");
const headroom = @import("headroom");
const rules = headroom.rules;
const scan = headroom.scan;
const wsl = headroom.wsl;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: zig build scan -- <folder|wsl:distribution> [threads]\n", .{});
        return 2;
    }
    const threads = if (args.len > 2) std.fmt.parseInt(usize, args[2], 10) catch 0 else 0;
    const a = std.heap.smp_allocator;
    const io = init.io;

    if (std.mem.eql(u8, args[1], "wsl:")) {
        const distros = try wsl.list(init.arena.allocator());
        for (distros) |d| std.debug.print("  {Bi:>10.1}  {s} (WSL {d}) {s}\n", .{ d.size, d.name, d.version, d.disk });
        return 0;
    }
    const start = std.Io.Clock.awake.now(io);
    const scanned = if (std.mem.startsWith(u8, args[1], "wsl:"))
        wsl.scanDistro(a, io, args[1][4..], null, null)
    else
        scan.scan(a, io, args[1], .{ .threads = threads });
    var tree = scanned catch |err| {
        std.debug.print("{s}: {s}\n", .{ args[1], @errorName(err) });
        return 1;
    };
    defer tree.deinit(a);
    const ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    const top = tree.node(scan.Tree.root_index);
    std.debug.print("{s}: {Bi:.1} in {d} files, {d} entries, {d} unreadable folders; {d} ms ({d} entries/s)\n", .{
        tree.root,
        top.size,
        top.files,
        tree.nodes.items.len,
        tree.unreadable,
        ms,
        tree.nodes.items.len * 1000 / @max(ms, 1),
    });

    // The ten biggest entries at the top.
    const first = top.first_child;
    const order = try a.alloc(u32, top.child_count);
    defer a.free(order);
    for (order, 0..) |*index, i| index.* = first + @as(u32, @intCast(i));
    std.mem.sort(u32, order, &tree, struct {
        fn bigger(t: *scan.Tree, l: u32, r: u32) bool {
            return t.node(l).size > t.node(r).size;
        }
    }.bigger);
    for (order[0..@min(order.len, 10)]) |index| {
        const n = tree.node(index);
        std.debug.print("  {Bi:>10.1}  {s}{s}\n", .{ n.size, tree.name(index), if (n.kind == .directory) std.fs.path.sep_str else "" });
    }

    // What can go, by rule.
    const found_at = std.Io.Clock.awake.now(io);
    const finds = try rules.find(a, &tree, scan.Tree.root_index);
    defer a.free(finds);
    const found_ms = found_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    var sizes: [rules.rules.len]u64 = @splat(0);
    var counts: [rules.rules.len]u32 = @splat(0);
    var total: u64 = 0;
    for (finds) |f| {
        sizes[f.rule] += tree.node(f.node).size;
        counts[f.rule] += 1;
        total += tree.node(f.node).size;
    }
    std.debug.print("\nreclaimable: {Bi:.1} in {d} places ({d} ms)\n", .{ total, finds.len, found_ms });
    for (rules.rules, 0..) |rule, r| {
        if (counts[r] == 0) continue;
        std.debug.print("  {Bi:>10.1}  {s} ({d})\n", .{ sizes[r], rule.title, counts[r] });
    }

    // Projects untouched for six months.
    const stale_at = std.Io.Clock.awake.now(io);
    const now = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const old = try headroom.projects.stale(init.arena.allocator(), &tree, scan.Tree.root_index, finds, now - 182 * 24 * 3600);
    const stale_ms = stale_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    var old_total: u64 = 0;
    for (old) |p| old_total += p.size;
    std.debug.print("\nold projects: {Bi:.1} in {d} ({d} ms)\n", .{ old_total, old.len, stale_ms });
    for (old[0..@min(old.len, 8)]) |p| std.debug.print("  {Bi:>10.1}  {s}\n", .{ p.size, tree.name(p.node) });

    // --map: what showing the top folder costs (the treemap at a big
    // window's size, the legend's sizes by kind).
    for (args) |arg| if (std.mem.eql(u8, arg, "--map")) {
        const layout_at = std.Io.Clock.awake.now(io);
        var layout = try headroom.treemap.layout(a, &tree, scan.Tree.root_index, .{ .x = 0, .y = 0, .w = 2400, .h = 1300 }, .{});
        defer layout.deinit(a);
        const layout_ms = layout_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        const legend_at = std.Io.Clock.awake.now(io);
        var kinds: [headroom.categories.count]u64 = @splat(0);
        for (tree.nodes.items, 0..) |n, i| {
            if (n.kind == .file) kinds[@intFromEnum(headroom.categories.of(tree.name(@intCast(i))))] += n.size;
        }
        const legend_ms = legend_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        std.debug.print("\nmap: {d} tiles in {d} ms; legend {d} ms\n", .{ layout.items.items.len, layout_ms, legend_ms });
        const touch_at = std.Io.Clock.awake.now(io);
        var sum: usize = 0;
        for (tree.nodes.items, 0..) |n, i| {
            if (n.kind == .file) sum +%= tree.name(@intCast(i))[0];
        }
        std.debug.print("names touched: {d} ms ({d})\n", .{ touch_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(), sum });
    };

    // --dupes: the duplicate search too.
    for (args) |arg| if (std.mem.eql(u8, arg, "--dupes")) {
        const dupes_at = std.Io.Clock.awake.now(io);
        const groups = try headroom.dupes.find(a, io, &tree, scan.Tree.root_index, .{});
        defer headroom.dupes.free(a, groups);
        const dupes_ms = dupes_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        var wasted: u64 = 0;
        for (groups) |g| wasted += g.size * (g.nodes.len - 1);
        std.debug.print("\nduplicates: {Bi:.1} wasted in {d} files ({d} ms)\n", .{ wasted, groups.len, dupes_ms });
        for (groups[0..@min(groups.len, 8)]) |g| {
            std.debug.print("  {Bi:>10.1}  {s} x{d}\n", .{ g.size, tree.name(g.nodes[0]), g.nodes.len });
        }
    };
    return 0;
}
