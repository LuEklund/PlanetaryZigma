const std = @import("std");
const Stat = @import("stats.zig").Stat;

pub const Item = struct {
    pub const Kind = enum(u16) {
        oxygen_tank = 0,
        energy_drink = 1,
        gun = 2,
        pickaxe = 3,
        rocket = 4,
        lightning = 5,

        pub fn getAttributeValues(kind: Kind) Attribute {
            return spec(kind).attributes;
        }
    };

    pub const Spec = struct {
        attributes: Attribute,
        model: []const u8,
        icon: []const u8,
    };

    pub fn spec(kind: Kind) Spec {
        return switch (kind) {
            .oxygen_tank => .{
                .attributes = .{ .health = 10 },
                .model = "objects/oxigen_tank.glb",
                .icon = "textures/oxygen_tank.png",
            },
            .energy_drink => .{
                .attributes = .{ .speed = 1 },
                .model = "objects/energy_drink.glb",
                .icon = "textures/energy_drink.png",
            },
            .gun => .{
                .attributes = .{ .damage = 1 },
                .model = "objects/gun.glb",
                .icon = "textures/gun.png",
            },
            .pickaxe => .{
                .attributes = .{ .attack_speed = 0.2 },
                .model = "objects/pickaxe.glb",
                .icon = "textures/pickaxe.png",
            },
            .rocket => .{
                .attributes = .{ .rocket_chance = 0.05 },
                .model = "objects/rocket.glb",
                .icon = "textures/rocket.png",
            },
            .lightning => .{
                .attributes = .{ .lightning_chance = 0.05 },
                .model = "objects/lightning.glb",
                .icon = "textures/lightning.png",
            },
        };
    }

    pub const Attribute = struct {
        health: f32 = 0,
        speed: f32 = 0,
        damage: f32 = 0,
        attack_speed: f32 = 0,
        range: f32 = 0,
        rocket_chance: f32 = 0,
        lightning_chance: f32 = 0,

        pub fn get(self: Attribute, kind: Stat.Kind) f32 {
            return switch (kind) {
                .health => self.health,
                .speed => self.speed,
                .damage => self.damage,
                .attack_speed => self.attack_speed,
                .range => self.range,
            };
        }
    };
};

pub const Inventory = struct {
    counts: std.EnumMap(Item.Kind, u8) = .initFull(0),

    pub fn get(self: Inventory, kind: Item.Kind) u8 {
        return self.counts.get(kind).?;
    }

    pub fn set(self: *Inventory, kind: Item.Kind, count: u8) void {
        self.counts.getPtr(kind).?.* = count;
    }

    pub fn add(self: *Inventory, kind: Item.Kind, delta: u8) u8 {
        const count = self.counts.getPtr(kind).?;
        count.* += delta;
        return count.*;
    }
};
