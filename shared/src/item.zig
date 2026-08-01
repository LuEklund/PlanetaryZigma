const std = @import("std");
const entity = @import("entity.zig");

pub const Item = enum(u16) {
    oxygen_tank,
    energy_drink,
    gun,
    pickaxe,
    rocket,
    lightning,
    crit,
    tougherer_times,
    icicle,
    hearth,

    pub const count: usize = @typeInfo(Item).@"enum".fields.len;

    pub const Spec = struct {
        flat: std.EnumArray(Stat, f32) = .initFill(0),
        percent: std.EnumArray(Stat, f32) = .initFill(0),
        description: []const u8,
        model: []const u8,
        icon: []const u8,
    };

    pub fn spec(item: Item) Spec {
        return switch (item) {
            .oxygen_tank => .{
                .flat = .initDefault(0, .{ .health = 10 }),
                .description = "+10 max health",
                .model = "objects/oxigen_tank.glb",
                .icon = "textures/oxygen_tank.png",
            },
            .energy_drink => .{
                .flat = .initDefault(0, .{ .speed = 1 }),
                .description = "+1 speed",
                .model = "objects/energy_drink.glb",
                .icon = "textures/energy_drink.png",
            },
            .gun => .{
                .flat = .initDefault(0, .{ .damage = 1 }),
                .description = "+1 damage",
                .model = "objects/gun.glb",
                .icon = "textures/gun.png",
            },
            .pickaxe => .{
                .percent = .initDefault(0, .{ .primary_cooldown = 0.15 }),
                .description = "+15% attack speed",
                .model = "objects/pickaxe.glb",
                .icon = "textures/pickaxe.png",
            },
            .rocket => .{
                .flat = .initDefault(0, .{ .rocket_chance = 0.05 }),
                .description = "5% chance to fire a rocket, stacks grow the blast",
                .model = "objects/rocket.glb",
                .icon = "textures/rocket.png",
            },
            .lightning => .{
                .flat = .initDefault(0, .{ .lightning_chance = 0.05 }),
                .description = "5% chance to chain lightning, stacks add jumps",
                .model = "objects/lightning.glb",
                .icon = "textures/lightning.png",
            },
            .crit => .{
                .flat = .initDefault(0, .{ .critical_chance = 0.1 }),
                .description = "10% chance to deal double damage",
                .model = "objects/item.glb",
                .icon = "textures/item.png",
            },
            .tougherer_times => .{
                .flat = .initDefault(0, .{ .block_chance = 0.15 }),
                .description = "15% chance to block damage, diminishing",
                .model = "objects/item.glb",
                .icon = "textures/item.png",
            },
            .icicle => .{
                .flat = .initDefault(0, .{ .stun_chance = 0.05 }),
                .description = "5% chance to stun on hit",
                .model = "objects/item.glb",
                .icon = "textures/item.png",
            },
            .hearth => .{
                .flat = .initDefault(0, .{ .regen = 1 }),
                .description = "+1 health regen",
                .model = "objects/item.glb",
                .icon = "textures/item.png",
            },
        };
    }
};

pub const Inventory = struct {
    counts: std.EnumMap(Item, u8) = .initFull(0),

    pub fn get(self: Inventory, item: Item) u8 {
        return self.counts.get(item).?;
    }

    pub fn set(self: *Inventory, item: Item, count: u8) void {
        self.counts.getPtr(item).?.* = count;
    }

    pub fn add(self: *Inventory, item: Item, delta: u8) u8 {
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
        for (std.enums.values(Item)) |item_kind| {
            const count: f32 = @floatFromInt(inv.get(item_kind));
            flat += item_kind.spec().flat.get(stat) * count;
            percent += item_kind.spec().percent.get(stat) * count;
        }
        const linear = (base_base.get(stat) + flat) * (1 + percent);
        return switch (stat) {
            .health, .speed, .damage, .regen, .rocket_chance, .lightning_chance, .critical_chance, .stun_chance => linear,
            .primary_cooldown, .utility_cooldown => @max(0.1, base_base.get(stat) + flat) / (1 + percent),
            .block_chance => 1 - 1 / (1 + linear),
        };
    }
};
