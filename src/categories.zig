//! What a file is, from its extension: the treemap's colors and the legend.
//! One table, read by the layer (colors) and the page (names, colors, totals).

const std = @import("std");

pub const Category = enum(u8) {
    code,
    build,
    binaries,
    archives,
    media,
    documents,
    data,
    other,
};

pub const count = @typeInfo(Category).@"enum".field_names.len;

pub const Info = struct {
    name: []const u8,
    /// sRGB, 0xRRGGBB: lit tiles on the night console.
    color: u24,
};

pub const info = std.enums.EnumArray(Category, Info).init(.{
    .code = .{ .name = "Source code", .color = 0x5b8def },
    .build = .{ .name = "Build output", .color = 0xd08a3c },
    .binaries = .{ .name = "Programs and libraries", .color = 0xd65a5f },
    .archives = .{ .name = "Archives and disk images", .color = 0x9b6fdc },
    .media = .{ .name = "Images, video, audio", .color = 0x3fb68f },
    .documents = .{ .name = "Documents", .color = 0xd9c25c },
    .data = .{ .name = "Data and logs", .color = 0x4fb4c9 },
    .other = .{ .name = "Everything else", .color = 0x7d8899 },
});

const table = [_]struct { Category, []const []const u8 }{
    .{ .code, &.{ "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "inl", "zig", "rs", "go", "py", "pyi", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "cs", "swift", "m", "mm", "rb", "php", "lua", "sh", "ps1", "bat", "cmake", "s", "asm", "html", "css", "scss", "vue", "svelte", "sql", "ll", "gvm", "zon" } },
    .{ .build, &.{ "o", "obj", "a", "lib", "pdb", "ilk", "pch", "gch", "rlib", "rmeta", "d", "exp", "idb", "tlog", "lastbuildstate", "class", "pyc", "pyo", "wasm", "bc", "incremental" } },
    .{ .binaries, &.{ "exe", "dll", "so", "dylib", "sys", "node", "msi", "appimage", "deb", "rpm", "elf", "efi", "ko" } },
    .{ .archives, &.{ "zip", "tar", "gz", "tgz", "xz", "txz", "bz2", "zst", "7z", "rar", "iso", "img", "vhd", "vhdx", "vmdk", "qcow2", "dmg", "cab", "jar", "whl", "nupkg", "crate" } },
    .{ .media, &.{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "psd", "svg", "ico", "heic", "raw", "mp4", "mkv", "mov", "avi", "webm", "mp3", "wav", "flac", "ogg", "m4a", "aac", "ttf", "otf", "woff", "woff2" } },
    .{ .documents, &.{ "pdf", "md", "txt", "rst", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "rtf", "epub", "tex" } },
    .{ .data, &.{ "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv", "db", "sqlite", "sqlite3", "parquet", "log", "bin", "dat", "pak", "npy", "npz", "pt", "safetensors", "gguf", "onnx", "h5", "pid", "ldb", "etl", "dmp" } },
};

/// Extension to category, made at compile time: millions of lookups after a
/// scan (the legend's totals).
const extensions = blk: {
    var n = 0;
    for (table) |row| n += row[1].len;
    var pairs: [n]struct { []const u8, Category } = undefined;
    var i = 0;
    for (table) |row| {
        for (row[1]) |ext| {
            pairs[i] = .{ ext, row[0] };
            i += 1;
        }
    }
    @setEvalBranchQuota(100_000);
    break :blk std.StaticStringMap(Category).initComptime(pairs);
};

/// The category of a file named `name`.
pub fn of(name: []const u8) Category {
    // Windows' memory on disk, not drivers for all their ".sys".
    for ([_][]const u8{ "pagefile.sys", "hiberfil.sys", "swapfile.sys" }) |memory| {
        if (std.ascii.eqlIgnoreCase(name, memory)) return .other;
    }
    // Versioned shared libraries: libLLVM.so.19.1, libz3.so.4.
    if (std.mem.indexOf(u8, name, ".so.") != null) return .binaries;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
    if (dot == 0 or dot + 1 == name.len) return .other;
    const extension = name[dot + 1 ..];
    if (extension.len > 16) return .other;
    var lower: [16]u8 = undefined;
    return extensions.get(std.ascii.lowerString(&lower, extension)) orelse .other;
}

test "categories" {
    try std.testing.expectEqual(Category.code, of("main.zig"));
    try std.testing.expectEqual(Category.binaries, of("ZEROG.DLL"));
    try std.testing.expectEqual(Category.binaries, of("libLLVM.so.19.1"));
    try std.testing.expectEqual(Category.other, of("pagefile.sys"));
    try std.testing.expectEqual(Category.binaries, of("ntfs.sys"));
    try std.testing.expectEqual(Category.build, of("combase.pdb"));
    try std.testing.expectEqual(Category.archives, of("ext4.vhdx"));
    try std.testing.expectEqual(Category.other, of(".gitignore"));
    try std.testing.expectEqual(Category.other, of("Makefile"));
    try std.testing.expectEqual(Category.other, of("trailing."));
}
