const Elite = @This();

const std = @import("std");
const Item = @import("Item.zig");

name: []const u8,
health_multiplier: f32,
damage_multiplier: f32,
cost_multiplier: f32,
granted_items: []const Grant,
tint: [3]f32,

pub const Grant = struct { item: Item.Kind, count: u8 };

pub const rows = struct {
    pub const none: Elite = .{
        .name = "",
        .health_multiplier = 1,
        .damage_multiplier = 1,
        .cost_multiplier = 1,
        .granted_items = &.{},
        .tint = .{ 1, 1, 1 },
    };
    pub const blazing: Elite = .{
        .name = "Blazing",
        .health_multiplier = 4,
        .damage_multiplier = 2,
        .cost_multiplier = 6,
        .granted_items = &.{.{ .item = .energy_drink, .count = 3 }},
        .tint = .{ 1, 0.45, 0.15 },
    };
    pub const glacial: Elite = .{
        .name = "Glacial",
        .health_multiplier = 4,
        .damage_multiplier = 1.5,
        .cost_multiplier = 6,
        .granted_items = &.{.{ .item = .icicle, .count = 8 }},
        .tint = .{ 0.55, 0.85, 1 },
    };
    pub const overloading: Elite = .{
        .name = "Overloading",
        .health_multiplier = 3,
        .damage_multiplier = 1.5,
        .cost_multiplier = 6,
        .granted_items = &.{.{ .item = .lightning, .count = 3 }},
        .tint = .{ 0.35, 0.5, 1 },
    };
};

pub const Kind = kind: {
    const decls = @typeInfo(rows).@"struct".decls;
    var field_names: [decls.len][]const u8 = undefined;
    var field_values: [decls.len]u8 = undefined;
    for (decls, &field_names, &field_values, 0..) |decl, *name, *value, index| {
        name.* = decl.name;
        value.* = index;
    }
    break :kind @Enum(u8, .exhaustive, &field_names, &field_values);
};

const all: [@typeInfo(rows).@"struct".decls.len]Elite = table: {
    var table: [@typeInfo(rows).@"struct".decls.len]Elite = undefined;
    for (@typeInfo(rows).@"struct".decls, &table) |decl, *slot| slot.* = @field(rows, decl.name);
    break :table table;
};

pub fn get(kind: Kind) *const Elite {
    return &all[@intFromEnum(kind)];
}

pub const min_coefficient: f32 = 1.3;
pub const chance: f32 = 0.25;

pub fn roll(random: std.Random) Kind {
    const affixes = std.enums.values(Kind);
    return affixes[1 + random.uintLessThan(usize, affixes.len - 1)];
}
