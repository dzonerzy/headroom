//! zig build scan -Doptimize=ReleaseFast -- <folder> [threads]: the scanner
//! alone on a real folder, how long it takes, and what is biggest in it.

const std = @import("std");
const scan = @import("scan");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: zig build scan -- <folder> [threads]\n", .{});
        return 2;
    }
    const threads = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 0;
    const a = std.heap.smp_allocator;
    const io = init.io;

    const start = std.Io.Clock.awake.now(io);
    var tree = scan.scan(a, io, args[1], .{ .threads = threads }) catch |err| {
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
    return 0;
}
