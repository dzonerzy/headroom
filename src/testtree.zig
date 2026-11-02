//! Tests' trees, built by hand: (parent, name, kind, size) in breadth-first
//! order (a folder's children side by side), totals summed as a scan does.

const std = @import("std");
const scan = @import("scan.zig");

pub const Entry = struct { u32, []const u8, scan.Kind, u64 };

pub fn make(a: std.mem.Allocator, root: []const u8, entries: []const Entry) !scan.Tree {
    var tree: scan.Tree = .{ .root = try a.dupeSentinel(u8, root, 0) };
    errdefer tree.deinit(a);
    try tree.names.appendSlice(a, root);
    try tree.nodes.append(a, .{ .parent = 0, .name_start = 0, .name_len = @intCast(root.len), .kind = .directory, .size = 0, .files = 0 });
    for (entries, 0..) |e, i| {
        const index: u32 = @intCast(i + 1);
        const start: u32 = @intCast(tree.names.items.len);
        try tree.names.appendSlice(a, e[1]);
        try tree.nodes.append(a, .{ .parent = e[0], .name_start = start, .name_len = @intCast(e[1].len), .kind = e[2], .size = e[3], .files = @intFromBool(e[2] == .file) });
        const parent = &tree.nodes.items[e[0]];
        if (parent.child_count == 0) parent.first_child = index;
        parent.child_count += 1;
    }
    var i = tree.nodes.items.len;
    while (i > 1) {
        i -= 1;
        const n = tree.nodes.items[i];
        tree.nodes.items[n.parent].size += n.size;
        tree.nodes.items[n.parent].files += n.files;
    }
    return tree;
}
