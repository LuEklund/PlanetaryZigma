const Item = @This();

const std = @import("std");
const entity = @import("entity.zig");

id: @EnumLiteral(),
flat: std.EnumArray(Stat, f32) = .initFill(0),
percent: std.EnumArray(Stat, f32) = .initFill(0),
description: []const u8,
is_equipment: bool = false,

pub const items: []const Item = &.{
    .{
        .id = .oxygen_tank,
        .flat = .initDefault(0, .{ .health = 10 }),
        .description = "+10 max health",
    },
    .{
        .id = .energy_drink,
        .flat = .initDefault(0, .{ .speed = 1 }),
        .description = "+1 speed",
    },
    .{
        .id = .gun,
        .flat = .initDefault(0, .{ .damage = 1 }),
        .description = "+1 damage",
    },
    .{
        .id = .pickaxe,
        .percent = .initDefault(0, .{ .primary_cooldown = 0.15 }),
        .description = "+15% attack speed",
    },
    .{
        .id = .rocket,
        .flat = .initDefault(0, .{ .rocket_chance = 0.05 }),
        .description = "5% chance to fire a rocket, stacks grow the blast",
    },
    .{
        .id = .lightning,
        .flat = .initDefault(0, .{ .lightning_chance = 0.05 }),
        .description = "5% chance to chain lightning, stacks add jumps",
    },
    .{
        .id = .scope,
        .flat = .initDefault(0, .{ .critical_chance = 0.1 }),
        .description = "10% chance to deal double damage",
    },
    .{
        .id = .rabbits_foot,
        .flat = .initDefault(0, .{ .block_chance = 0.15 }),
        .description = "15% chance to block damage, diminishing",
    },
    .{
        .id = .icicle,
        .flat = .initDefault(0, .{ .stun_chance = 0.05 }),
        .description = "5% chance to stun on hit",
    },
    .{
        .id = .heart,
        .flat = .initDefault(0, .{ .regen = 1 }),
        .description = "+1 health regen",
    },
    .{
        .id = .freezer,
        .description = "freeze time for 20s",
        .is_equipment = true,
    },
};

pub const model_paths: [items.len][]const u8 = paths: {
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = "objects/" ++ @tagName(item.id) ++ ".glb";
    }
    break :paths paths;
};

pub const icon_paths: [items.len][]const u8 = paths: {
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = "textures/" ++ @tagName(item.id) ++ ".png";
    }
    break :paths paths;
};

pub const Kind = kind: {
    const TagInt = u16;
    var field_names: [items.len][]const u8 = undefined;
    var field_values: [field_names.len]TagInt = undefined;
    for (items, &field_names, &field_values, 0..) |spec, *name, *value, i| {
        name.* = @tagName(spec.id);
        value.* = i;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

// same as spec alright Lucas
pub fn get(kind: Kind) Item {
    return items[@intFromEnum(kind)];
}

pub fn getModel(kind: Kind) []const u8 {
    return model_paths[@intFromEnum(kind)];
}

pub fn getIcon(kind: Kind) []const u8 {
    return icon_paths[@intFromEnum(kind)];
}

pub const Inventory = struct {
    counts: std.EnumMap(Item.Kind, u8) = .initFull(0),

    pub fn get(self: Inventory, item: Item.Kind) u8 {
        return self.counts.get(item).?;
    }

    pub fn set(self: *Inventory, item: Item.Kind, count: u8) void {
        self.counts.getPtr(item).?.* = count;
    }

    pub fn add(self: *Inventory, item: Item.Kind, delta: u8) u8 {
        const count = self.counts.getPtr(item).?;
        count.* += delta;
        return count.*;
    }
};

pub const Stat = enum(u16) {
    health,
    speed,
    damage,
    primary_cooldown,
    utility_cooldown,
    regen,
    rocket_chance,
    lightning_chance,
    critical_chance,
    block_chance,
    stun_chance,

    pub fn value(stat: Stat, entity_kind: entity.Kind, inv: Inventory) f32 {
        const base_base: std.EnumArray(Stat, f32) = entity.spec(entity_kind).base_stats orelse .initFill(0);
        var flat: f32 = 0;
        var percent: f32 = 0;
        inline for (std.enums.values(Item.Kind)) |item_kind| {
            const count: f32 = @floatFromInt(inv.get(item_kind));
            flat += get(item_kind).flat.get(stat) * count;
            percent += get(item_kind).percent.get(stat) * count;
        }
        const linear = (base_base.get(stat) + flat) * (1 + percent);
        return switch (stat) {
            .health, .speed, .damage, .regen, .rocket_chance, .lightning_chance, .critical_chance, .stun_chance => linear,
            .primary_cooldown, .utility_cooldown => @max(0.1, base_base.get(stat) + flat) / (1 + percent),
            .block_chance => 1 - 1 / (1 + linear),
        };
    }
};
