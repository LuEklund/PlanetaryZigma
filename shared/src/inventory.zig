const std = @import("std");
const Stat = @import("stats.zig").Stat;

pub const Item = struct {
    pub const Kind = enum(u16) {
        health = 0,
        speed = 1,
        damage = 2,
        attack_speed = 3,
        rocket = 4,

        pub fn getAttributeValues(kind: Kind) Attribute {
            return switch (kind) {
                .health => .{ .health = 10 },
                .speed => .{ .speed = 1 },
                .damage => .{ .damage = 1 },
                .attack_speed => .{ .attack_speed = 0.2 },
                .rocket => .{ .rocket_chance = 0.05 },
            };
        }
    };

    pub const Attribute = struct {
        health: f32 = 0,
        speed: f32 = 0,
        damage: f32 = 0,
        attack_speed: f32 = 0,
        range: f32 = 0,
        rocket_chance: f32 = 0,

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
