const std = @import("std");
const Item = @import("Item.zig");

pub const Kind = union(enum) {
    blank,
    missing,
    skybox_cubemap,
    crosshair,
    item: Item.Kind,
};

/// blank and missing own descriptor slots 0 and 1 and load no file.
pub const reserved = 2;
const named_files = [_]std.meta.Tag(Kind){ .skybox_cubemap, .crosshair };

pub const paths_capacity = named_files.len + Item.items.len;

pub fn count() usize {
    return reserved + paths_capacity;
}

/// The files to load, in slot order: named first, then one per item.
pub fn paths(buffer: *[paths_capacity][]const u8) []const []const u8 {
    inline for (named_files, 0..) |named, index| buffer[index] = @tagName(named) ++ ".png";
    var found: usize = named_files.len;
    for (Item.icon_paths) |path| {
        buffer[found] = path["textures/".len..];
        found += 1;
    }
    return buffer[0..found];
}

pub fn slot(kind: Kind) usize {
    return switch (kind) {
        .blank => 0,
        .missing => 1,
        .item => |item| reserved + named_files.len + @as(usize, @intFromEnum(item)),
        else => reserved + std.mem.indexOfScalar(std.meta.Tag(Kind), &named_files, kind).?,
    };
}
