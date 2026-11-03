//! What tools/scan.zig uses (one module, the files in it once): the
//! scanner, the rules, WSL's distributions.

pub const scan = @import("scan.zig");
pub const rules = @import("rules.zig");
pub const wsl = @import("wsl.zig");
pub const dupes = @import("dupes.zig");
pub const projects = @import("projects.zig");
pub const treemap = @import("treemap.zig");
pub const categories = @import("categories.zig");
