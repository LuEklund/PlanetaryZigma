const Elite = @This();

const std = @import("std");
const Item = @import("Item.zig");

name: []const u8,
health_multiplier: f32,
damage_multiplier: f32,
cost_multiplier: f32,
granted_items: []const Grant,
tint: [3]f32,
/// RoR2 elite tier: 1 always, 2 only on looped stages (×36 cost).
tier: u8 = 1,

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
    pub const malachite: Elite = .{
        .name = "Malachite",
        .health_multiplier = 18,
        .damage_multiplier = 6,
        .cost_multiplier = 36,
        .granted_items = &.{ .{ .item = .thorn_vest, .count = 2 }, .{ .item = .leech_fang, .count = 2 } },
        .tint = .{ 0.2, 0.9, 0.55 },
        .tier = 2,
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

/// A random affix of exactly `tier`.
pub fn roll(random: std.Random, tier: u8) Kind {
    var count: usize = 0;
    for (std.enums.values(Kind)) |kind| {
        if (kind != .none and get(kind).tier == tier) count += 1;
    }
    var pick = random.uintLessThan(usize, count);
    for (std.enums.values(Kind)) |kind| {
        if (kind == .none or get(kind).tier != tier) continue;
        if (pick == 0) return kind;
        pick -= 1;
    }
    unreachable;
}
