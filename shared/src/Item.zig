const Item = @This();

const std = @import("std");
const nz = @import("numz");

name: @EnumLiteral(),
modifiers: struct {
    health: f32 = 0.0,
    speed: f32 = 0.0,
    damage: f32 = 0.0,
    attack_speed: f32 = 0.0,
    range: f32 = 0.0,
},

pub const Kind = e: {
    const TagInt = u16;

    var field_names: [items.len][]const u8 = undefined;
    var field_values: [items.len]TagInt = undefined;
    for (items, 0..) |item, i| field_names[i] = @tagName(item.name);
    for (0..items.len) |i| field_values[i] = i;

    break :e @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub const Model = struct {
    path: []const u8,
};

pub const Texture = struct {
    path: []const u8,
};

pub const items: []const Item = &.{
    .{
        .name = .oxygen_tank,
        .modifiers = .{
            .health = 90.0,
        },
    },
    .{
        .name = .gun,
        .modifiers = .{
            .damage = 1.5,
        },
    },
    .{
        .name = .energy_drink,
        .modifiers = .{
            .speed = 0.75,
        },
    },
    .{
        .name = .pickaxe,
        .modifiers = .{
            .attack_speeed = 0.2,
        },
    },
};

pub const models: std.EnumArray(Kind, Model) = .init(.{
    .oxygen_tank = .{ .path = "objects/oxigen_tank.glb" }, // TODO: fix spelling for oxigen_tank glb
    .gun = .{ .path = "objects/gun.glb" },
    .energy_drink = .{ .path = "energy_drink.glb" },
    .pickaxe = .{ .path = "objects/pickaxe2.glb" },
});

pub const textures: std.EnumArray(Kind, Texture) = .init(.{
    .oxygen_tank = .{ .path = "items/oxygen_tank.png" },
    .gun = .{ .path = "items/damage.png" }, // TODO: rename damage.png to gun.png
    .energy_drink = .{ .path = "items/energy_drink.png" },
    .pickaxe = .{ .path = "items/pickaxe.png" },
});
