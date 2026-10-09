const Item = @This();

const std = @import("std");

flat: std.EnumArray(Stat, f32) = .initFill(0),
percent: std.EnumArray(Stat, f32) = .initFill(0),
description: []const u8,
tier: Tier = .common,
is_equipment: bool = false,
on_use: ?Effect = null,
procs: []const Proc = &.{},

pub const Tier = enum {
    common,
    uncommon,
    legendary,
    boss,
    equipment,
    lunar,
};

pub const ChestOdds = struct { tier: Tier, weight: f32 };

pub const small_chest_odds = [_]ChestOdds{
    .{ .tier = .common, .weight = 0.75 },
    .{ .tier = .uncommon, .weight = 0.19 },
    .{ .tier = .legendary, .weight = 0.01 },
    .{ .tier = .equipment, .weight = 0.05 },
    .{ .tier = .lunar, .weight = 0.02 },
};

pub fn rollTier(odds: []const ChestOdds, random: std.Random) Tier {
    var total: f32 = 0;
    for (odds) |entry| total += entry.weight;
    var pick = random.float(f32) * total;
    for (odds) |entry| {
        if (pick < entry.weight) return entry.tier;
        pick -= entry.weight;
    }
    return odds[odds.len - 1].tier;
}

pub fn rollFromTier(tier: Tier, random: std.Random) ?Kind {
    var count: usize = 0;
    for (std.enums.values(Kind)) |kind| {
        if (get(kind).tier == tier) count += 1;
    }
    if (count == 0) return null;
    var pick = random.uintLessThan(usize, count);
    for (std.enums.values(Kind)) |kind| {
        if (get(kind).tier != tier) continue;
        if (pick == 0) return kind;
        pick -= 1;
    }
    unreachable;
}

pub fn rollChest(odds: []const ChestOdds, random: std.Random) Kind {
    const tier = rollTier(odds, random);
    if (rollFromTier(tier, random)) |kind| return kind;
    return rollFromTier(.common, random).?;
}

pub const Effect = enum {
    freeze_world,
    heal_burst,
    blast_wave,
};

pub const Trigger = enum { on_hit, on_kill, on_hurt };

pub const Proc = struct {
    trigger: Trigger,
    chance: f32,
    effect: ProcEffect,
};

pub const ProcEffect = union(enum) {
    heal: f32,
    leech: f32,
    gold: u32,
    blast: struct { radius: f32, radius_per_stack: f32, damage_fraction: f32 },
    healthy_bonus: struct { threshold: f32, damage_fraction: f32 },
    thorns: f32,
};

pub const items = struct {
    pub const oxygen: Item = .{
        .flat = .initDefault(0, .{ .health = 10 }),
        .description = "+10 max health",
    };

    pub const energy_drink: Item = .{
        .flat = .initDefault(0, .{ .speed = 1 }),
        .description = "+1 speed",
    };

    pub const gun: Item = .{
        .flat = .initDefault(0, .{ .damage = 1 }),
        .description = "+1 damage",
    };

    pub const pickaxe: Item = .{
        .percent = .initDefault(0, .{ .primary_cooldown = 0.15 }),
        .description = "+15% attack speed",
    };

    pub const rocket: Item = .{
        .tier = .uncommon,
        .flat = .initDefault(0, .{ .rocket_chance = 0.05 }),
        .description = "5% chance to fire a rocket, stacks grow the blast",
    };

    pub const lightning: Item = .{
        .tier = .boss,
        .flat = .initDefault(0, .{ .lightning_chance = 0.05 }),
        .description = "5% chance to chain lightning, stacks add jumps",
    };

    pub const scope: Item = .{
        .tier = .uncommon,
        .flat = .initDefault(0, .{ .critical_chance = 0.1 }),
        .description = "10% chance to deal double damage",
    };

    pub const rabbitsfoot: Item = .{
        .tier = .uncommon,
        .flat = .initDefault(0, .{ .block_chance = 0.15 }),
        .description = "15% chance to block damage, diminishing",
    };

    pub const icicle: Item = .{
        .tier = .uncommon,
        .flat = .initDefault(0, .{ .stun_chance = 0.05 }),
        .description = "5% chance to stun on hit",
    };

    pub const heart: Item = .{
        .flat = .initDefault(0, .{ .regen = 1 }),
        .description = "+1 health regen",
    };

    pub const leech_seed: Item = .{
        .procs = &.{.{ .trigger = .on_hit, .chance = 1, .effect = .{ .heal = 1 } }},
        .description = "heal 1 per hit, +1 per stack",
    };

    pub const coin_pouch: Item = .{
        .procs = &.{.{ .trigger = .on_kill, .chance = 1, .effect = .{ .gold = 1 } }},
        .description = "+1 gold per kill, +1 per stack",
    };

    pub const crowbar: Item = .{
        .procs = &.{.{ .trigger = .on_hit, .chance = 1, .effect = .{ .healthy_bonus = .{ .threshold = 0.9, .damage_fraction = 0.75 } } }},
        .description = "+75% damage to enemies above 90% health, +75% per stack",
    };

    pub const boots: Item = .{
        .percent = .initDefault(0, .{ .speed = 0.14 }),
        .description = "+14% movement speed",
    };

    pub const bandage: Item = .{
        .procs = &.{.{ .trigger = .on_hurt, .chance = 0.25, .effect = .{ .heal = 4 } }},
        .description = "25% chance to heal 4 when hurt, +4 per stack",
    };

    pub const gasoline: Item = .{
        .tier = .uncommon,
        .procs = &.{.{ .trigger = .on_kill, .chance = 1, .effect = .{ .blast = .{ .radius = 4, .radius_per_stack = 1.5, .damage_fraction = 1.5 } } }},
        .description = "kills explode for 150% damage, bigger blast per stack",
    };

    pub const thorn_vest: Item = .{
        .tier = .uncommon,
        .procs = &.{.{ .trigger = .on_hurt, .chance = 1, .effect = .{ .thorns = 0.5 } }},
        .description = "return 50% of damage taken to the attacker, +50% per stack",
    };

    pub const vampire_fang: Item = .{
        .tier = .uncommon,
        .procs = &.{.{ .trigger = .on_kill, .chance = 1, .effect = .{ .heal = 8 } }},
        .description = "heal 8 on kill, +8 per stack",
    };

    pub const ghor_tome: Item = .{
        .tier = .uncommon,
        .procs = &.{.{ .trigger = .on_kill, .chance = 0.2, .effect = .{ .gold = 15 } }},
        .description = "20% chance on kill to drop 15 gold, +15 per stack",
    };

    pub const leech_fang: Item = .{
        .tier = .uncommon,
        .procs = &.{.{ .trigger = .on_hit, .chance = 1, .effect = .{ .leech = 0.05 } }},
        .description = "heal 5% of damage dealt, +5% per stack",
    };

    pub const brilliant_hammer: Item = .{
        .tier = .legendary,
        .procs = &.{.{ .trigger = .on_hit, .chance = 1, .effect = .{ .blast = .{ .radius = 3, .radius_per_stack = 2.5, .damage_fraction = 0.6 } } }},
        .description = "every hit explodes for 60% damage, bigger blast per stack",
    };

    pub const berserker_core: Item = .{
        .tier = .legendary,
        .percent = .initDefault(0, .{ .damage = 0.5, .primary_cooldown = 0.3 }),
        .description = "+50% damage, +30% attack speed",
    };

    pub const glass_heart: Item = .{
        .tier = .lunar,
        .percent = .initDefault(0, .{ .damage = 0.6, .health = -0.25 }),
        .description = "+60% damage, -25% max health",
    };

    pub const blood_pact: Item = .{
        .tier = .lunar,
        .flat = .initDefault(0, .{ .health = -20, .regen = 2 }),
        .percent = .initDefault(0, .{ .damage = 0.3 }),
        .description = "+30% damage, +2 regen, -20 max health",
    };

    pub const heal_spray: Item = .{
        .description = "heal everyone near you for half their health",
        .tier = .equipment,
        .is_equipment = true,
        .on_use = .heal_burst,
    };

    pub const blast_wave: Item = .{
        .description = "blast every enemy within 15 for 500% damage",
        .tier = .equipment,
        .is_equipment = true,
        .on_use = .blast_wave,
    };

    pub const freezer: Item = .{
        .tier = .equipment,
        .flat = .initDefault(0, .{ .equipment_cooldown = 20 }),
        .description = "freeze nearby enemies for 10s",
        .is_equipment = true,
        .on_use = .freeze_world,
    };
};

const item_count: usize = @typeInfo(items).@"struct".decls.len;

const items_array: [item_count]Item = rows: {
    var rows: [item_count]Item = undefined;
    for (@typeInfo(items).@"struct".decls, &rows) |decl, *row| row.* = @field(items, decl.name);
    break :rows rows;
};

pub const model_paths: [item_count][]const u8 = paths: {
    var paths: [item_count][]const u8 = undefined;
    for (@typeInfo(items).@"struct".decls, &paths) |decl, *path| {
        path.* = "objects/" ++ decl.name ++ ".glb";
    }
    break :paths paths;
};

pub const icon_paths: [item_count][]const u8 = paths: {
    var paths: [item_count][]const u8 = undefined;
    for (@typeInfo(items).@"struct".decls, &paths) |decl, *path| {
        path.* = "textures/" ++ decl.name ++ ".png";
    }
    break :paths paths;
};

pub const Kind = kind: {
    const decls = @typeInfo(items).@"struct".decls;
    const TagInt = u16;
    var field_names: [item_count][]const u8 = undefined;
    var field_values: [item_count]TagInt = undefined;
    for (decls, &field_names, &field_values, 0..) |decl, *name, *value, index| {
        name.* = decl.name;
        value.* = index;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub fn get(kind: Kind) *const Item {
    return &items_array[@intFromEnum(kind)];
}

pub fn getModel(kind: Kind) []const u8 {
    return model_paths[@intFromEnum(kind)];
}

pub const Inventory = struct {
    counts: std.EnumArray(Item.Kind, u8) = .initFill(0),

    pub fn get(self: Inventory, item: Item.Kind) u8 {
        return self.counts.get(item);
    }

    pub fn set(self: *Inventory, item: Item.Kind, count: u8) void {
        self.counts.set(item, count);
    }

    pub fn add(self: *Inventory, item: Item.Kind, delta: u8) u8 {
        const count = self.counts.getPtr(item);
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

    pub fn value(stat: Stat, base: *const std.EnumArray(Stat, f32), inv: Inventory) f32 {
        var flat: f32 = 0;
        var percent: f32 = 0;
        for (std.enums.values(Item.Kind)) |item_kind| {
            const count: f32 = @floatFromInt(inv.get(item_kind));
            if (count == 0) continue;
            const item = get(item_kind);
            flat += item.flat.get(stat) * count;
            percent += item.percent.get(stat) * count;
        }
        const linear = (base.get(stat) + flat) * @max(min_percent_scale, 1 + percent);
        return switch (stat) {
            .health, .speed, .damage, .regen, .rocket_chance, .lightning_chance, .critical_chance, .stun_chance => linear,
            .primary_cooldown, .utility_cooldown, .secondary_cooldown, .equipment_cooldown => @max(0.1, base.get(stat) + flat) / @max(0.01, 1 + percent),
            .block_chance => 1 - 1 / (1 + linear),
        };
    }
};

pub const min_percent_scale: f32 = 0.1;

pub fn equippedEffect(inv: Inventory) ?Effect {
    for (std.enums.values(Kind)) |kind| {
        if (get(kind).on_use) |effect| {
            if (inv.get(kind) > 0) return effect;
        }
    }
    return null;
}
