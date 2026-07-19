const std = @import("std");
const Stats = @import("Stats.zig");

pub const Item = enum(u16) {
    oxygen_tank = 0,
    energy_drink = 1,
    gun = 2,
    pickaxe = 3,
    rocket = 4,
    lightning = 5,

    pub const Spec = struct {
        attributes: Stats.Values,
        model: []const u8,
        icon: []const u8,
    };

    pub fn spec(item: Item) Spec {
        return switch (item) {
            .oxygen_tank => .{
                .attributes = .initDefault(0, .{ .health = 10 }),
                .model = "objects/oxigen_tank.glb",
                .icon = "textures/oxygen_tank.png",
            },
            .energy_drink => .{
                .attributes = .initDefault(0, .{ .speed = 1 }),
                .model = "objects/energy_drink.glb",
                .icon = "textures/energy_drink.png",
            },
            .gun => .{
                .attributes = .initDefault(0, .{ .damage = 1 }),
                .model = "objects/gun.glb",
                .icon = "textures/gun.png",
            },
            .pickaxe => .{
                .attributes = .initDefault(0, .{ .attack_speed = 0.2 }),
                .model = "objects/pickaxe.glb",
                .icon = "textures/pickaxe.png",
            },
            .rocket => .{
                .attributes = .initDefault(0, .{ .rocket_chance = 0.05 }),
                .model = "objects/rocket.glb",
                .icon = "textures/rocket.png",
            },
            .lightning => .{
                .attributes = .initDefault(0, .{ .lightning_chance = 0.05 }),
                .model = "objects/lightning.glb",
                .icon = "textures/lightning.png",
            },
        };
    }

    pub fn attributes(item: Item) Stats.Values {
        return item.spec().attributes;
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
