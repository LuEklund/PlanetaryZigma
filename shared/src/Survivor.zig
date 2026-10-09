const Survivor = @This();

const std = @import("std");
const entity = @import("entity.zig");
const Item = @import("Item.zig");

name: []const u8,
description: []const u8,
base_stats: std.EnumArray(Item.Stat, f32),
abilities: std.EnumArray(entity.Action, ?entity.AssignedSkill),

pub const rows = struct {
    pub const commando: Survivor = .{
        .name = "Commando",
        .description = "Fast gunner. Bullets, a shotgun burst, a dash and a grenade.",
        .base_stats = .initDefault(0, .{
            .health = 100,
            .speed = 10,
            .damage = 1,
            .regen = 1,
            .primary_cooldown = 0.3,
            .secondary_cooldown = 5,
            .utility_cooldown = 5,
            .special_cooldown = 8,
            .equipment_cooldown = 5,
        }),
        .abilities = .initDefault(null, .{
            .primary = .{ .skill = .shoot, .range = 10, .clip = "Run" },
            .secondary = .{ .skill = .spread_shot, .hits = 6, .damage_multiplier = 0.7 },
            .utility = .{ .skill = .dash },
            .special = .{ .skill = .grenade, .damage_multiplier = 4, .clip = "Throw" },
            .equipment = .{ .skill = .use_equipment },
        }),
    };

    pub const brawler: Survivor = .{
        .name = "Brawler",
        .description = "Tough melee fighter. Wide swings, a ground slam, a leap and a war cry that heals allies.",
        .base_stats = .initDefault(0, .{
            .health = 160,
            .speed = 9,
            .damage = 2,
            .regen = 2,
            .primary_cooldown = 0.5,
            .secondary_cooldown = 4,
            .utility_cooldown = 6,
            .special_cooldown = 14,
            .equipment_cooldown = 5,
        }),
        .abilities = .initDefault(null, .{
            .primary = .{ .skill = .melee_cone, .range = 3.5, .damage_multiplier = 1.5, .clip = "Throw" },
            .secondary = .{ .skill = .ground_slam, .radius = 6, .damage_multiplier = 3 },
            .utility = .{ .skill = .blink, .range = 14 },
            .special = .{ .skill = .heal_pulse, .radius = 12, .damage_multiplier = 0.35 },
            .equipment = .{ .skill = .use_equipment },
        }),
    };

    pub const marksman: Survivor = .{
        .name = "Marksman",
        .description = "Fragile sniper. Piercing rail shots, a grenade, a long blink and an artillery strike.",
        .base_stats = .initDefault(0, .{
            .health = 80,
            .speed = 10,
            .damage = 1.2,
            .regen = 1,
            .primary_cooldown = 0.9,
            .secondary_cooldown = 6,
            .utility_cooldown = 7,
            .special_cooldown = 12,
            .equipment_cooldown = 5,
        }),
        .abilities = .initDefault(null, .{
            .primary = .{ .skill = .railgun, .damage_multiplier = 4, .clip = "shoot" },
            .secondary = .{ .skill = .grenade, .damage_multiplier = 3, .clip = "Throw" },
            .utility = .{ .skill = .blink, .range = 20 },
            .special = .{ .skill = .artillery, .radius = 7, .damage_multiplier = 6 },
            .equipment = .{ .skill = .use_equipment },
        }),
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

const all: [@typeInfo(rows).@"struct".decls.len]Survivor = table: {
    var table: [@typeInfo(rows).@"struct".decls.len]Survivor = undefined;
    for (@typeInfo(rows).@"struct".decls, &table) |decl, *slot| slot.* = @field(rows, decl.name);
    break :table table;
};

pub fn get(kind: Kind) *const Survivor {
    return &all[@intFromEnum(kind)];
}
