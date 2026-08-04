const std = @import("std");
const Item = @import("Item.zig");

/// Every texture the game can name.
///
/// `blank` and `missing` are the renderer's two reserved descriptor slots and load no
/// file. The rest are spelled out so the editor completes them. Item icons are not
/// restated here — `Item` already declares one per item, so an icon's slot is just its
/// position in that table.
pub const Kind = union(enum) {
    blank,
    missing,
    skybox_cubemap,
    crosshair,
    item: Item.Kind,
};

/// blank and missing own descriptor slots 0 and 1 and load no file, so the file list
/// starts after them. Every arm below is one file, in this order.
pub const reserved = 2;
const file_arms = 2;

pub const paths_capacity = file_arms + Item.items.len;

pub fn count() usize {
    return reserved + paths_capacity;
}

/// The files to load, in slot order: named first, then one per item. The loader builds
/// its list from this, so file order and slot index cannot disagree.
pub fn paths(buffer: *[paths_capacity][]const u8) []const []const u8 {
    buffer[0] = @tagName(Kind.skybox_cubemap) ++ ".png";
    buffer[1] = @tagName(Kind.crosshair) ++ ".png";
    var found: usize = file_arms;
    for (Item.icon_paths) |path| {
        buffer[found] = path["textures/".len..];
        found += 1;
    }
    return buffer[0..found];
}

/// Index into the caller-owned slot array.
pub fn slot(kind: Kind) usize {
    return switch (kind) {
        .blank => 0,
        .missing => 1,
        .skybox_cubemap => 2,
        .crosshair => 3,
        .item => |item| reserved + file_arms + @as(usize, @intFromEnum(item)),
    };
}
