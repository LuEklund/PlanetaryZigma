const Item = @This();

const std = @import("std");
const entity = @import("entity.zig");

name: []const u8,
flat: std.EnumArray(Stat, f32) = .initFill(0),
percent: std.EnumArray(Stat, f32) = .initFill(0),
description: []const u8,
is_equipment: bool = false,
on_use: ?Effect = null,

pub const Effect = enum {
    freeze_world,
};

pub const items: []const Item = &.{
    .{
        .name = "oxygen_tank",
        .flat = .initDefault(0, .{ .health = 10 }),
        .description = "+10 max health",
    },
    .{
        .name = "energy_drink",
        .flat = .initDefault(0, .{ .speed = 1 }),
        .description = "+1 speed",
    },
    .{
        .name = "gun",
        .flat = .initDefault(0, .{ .damage = 1 }),
        .description = "+1 damage",
    },
    .{
        .name = "pickaxe",
        .percent = .initDefault(0, .{ .primary_cooldown = 0.15 }),
        .description = "+15% attack speed",
    },
    .{
        .name = "rocket",
        .flat = .initDefault(0, .{ .rocket_chance = 0.05 }),
        .description = "5% chance to fire a rocket, stacks grow the blast",
    },
    .{
        .name = "lightning",
        .flat = .initDefault(0, .{ .lightning_chance = 0.05 }),
        .description = "5% chance to chain lightning, stacks add jumps",
    },
    .{
        .name = "scope",
        .flat = .initDefault(0, .{ .critical_chance = 0.1 }),
        .description = "10% chance to deal double damage",
    },
    .{
        .name = "rabbits_foot",
        .flat = .initDefault(0, .{ .block_chance = 0.15 }),
        .description = "15% chance to block damage, diminishing",
    },
    .{
        .name = "icicle",
        .flat = .initDefault(0, .{ .stun_chance = 0.05 }),
        .description = "5% chance to stun on hit",
    },
    .{
        .name = "heart",
        .flat = .initDefault(0, .{ .regen = 1 }),
        .description = "+1 health regen",
    },
    .{
        .name = "freezer",
        .description = "freeze time for 20s",
        .is_equipment = true,
        .on_use = .freeze_world,
    },
};

pub const model_paths: [items.len][]const u8 = paths: {
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = "objects/" ++ item.name ++ ".glb";
    }
    break :paths paths;
};

pub const icon_paths: [items.len][]const u8 = paths: {
    var paths: [items.len][]const u8 = undefined;
    for (items, &paths) |item, *path| {
        path.* = "textures/" ++ item.name ++ ".png";
    }
    break :paths paths;
};

pub const Kind = kind: {
    const TagInt = u16;
    var field_names: [items.len][]const u8 = undefined;
    var field_values: [field_names.len]TagInt = undefined;
    for (items, &field_names, &field_values, 0..) |spec, *name, *value, i| {
        name.* = spec.name;
        value.* = i;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub fn get(kind: Kind) *const Item {
    return &items[@intFromEnum(kind)];
}

pub fn getModel(kind: Kind) []const u8 {
    return model_paths[@intFromEnum(kind)];
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
    secondary_cooldown,
    equipment_cooldown,
    regen,
    rocket_chance,
    lightning_chance,
    critical_chance,
    block_chance,
    stun_chance,

    pub const zero: std.EnumArray(Stat, f32) = .initFill(0);

    pub fn value(stat: Stat, base: *const std.EnumArray(Stat, f32), inv: Inventory) f32 {
        var flat: f32 = 0;
        var percent: f32 = 0;
        for (std.enums.values(Item.Kind)) |item_kind| {
            const count: f32 = @floatFromInt(inv.get(item_kind));
            flat += get(item_kind).flat.get(stat) * count;
            percent += get(item_kind).percent.get(stat) * count;
        }
        return shape(stat, base.get(stat), flat, percent);
    }

    pub fn all(base: *const std.EnumArray(Stat, f32), inv: Inventory) std.EnumArray(Stat, f32) {
        var flat: std.EnumArray(Stat, f32) = .initFill(0);
        var percent: std.EnumArray(Stat, f32) = .initFill(0);
        for (std.enums.values(Item.Kind)) |item_kind| {
            const count: f32 = @floatFromInt(inv.get(item_kind));
            if (count == 0) continue;
            const row = get(item_kind);
            for (std.enums.values(Stat)) |stat| {
                flat.getPtr(stat).* += row.flat.get(stat) * count;
                percent.getPtr(stat).* += row.percent.get(stat) * count;
            }
        }
        var shaped: std.EnumArray(Stat, f32) = undefined;
        for (std.enums.values(Stat)) |stat| {
            shaped.set(stat, shape(stat, base.get(stat), flat.get(stat), percent.get(stat)));
        }
        return shaped;
    }

    fn shape(stat: Stat, base: f32, flat: f32, percent: f32) f32 {
        const linear = (base + flat) * (1 + percent);
        return switch (stat) {
            .health, .speed, .damage, .regen, .rocket_chance, .lightning_chance, .critical_chance, .stun_chance => linear,
            .primary_cooldown, .utility_cooldown, .secondary_cooldown, .equipment_cooldown => @max(0.1, base + flat) / (1 + percent),
            .block_chance => 1 - 1 / (1 + linear),
        };
    }
};

pub fn equippedEffect(inv: Inventory) ?Effect {
    for (std.enums.values(Kind)) |kind| {
        if (get(kind).on_use) |effect| {
            if (inv.get(kind) > 0) return effect;
        }
    }
    return null;
}

pub fn cooldownStat(action: entity.Action) Stat {
    return switch (action) {
        .primary => .primary_cooldown,
        .secondary => .secondary_cooldown,
        .utility => .utility_cooldown,
        .equipment => .equipment_cooldown,
    };
}
