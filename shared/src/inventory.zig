const std = @import("std");
const Stat = @import("stats.zig").Stat;

pub const Item = struct {
    pub const Kind = enum(u16) {
        health_potion,
        speed_potion,
        damage_potion,
        attack_speed_potion,
    };

    pub const Attribute = struct {
        health: f32 = 0,
        speed: f32 = 0,
        damage: f32 = 0,
        attack_speed: f32 = 0,

        pub fn get(self: Attribute, kind: Stat.Kind) f32 {
            return switch (kind) {
                .health => self.health,
                .speed => self.speed,
                .damage => self.damage,
                .attack_speed => self.attack_speed,
            };
        }
    };

    pub fn getAttributeValues(kind: Item.Kind) Attribute {
        return switch (kind) {
            .health_potion => .{ .health = 10 },
            .speed_potion => .{ .speed = 1 },
            .damage_potion => .{ .damage = 1 },
            .attack_speed_potion => .{ .attack_speed = 0.2 },
        };
    }
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
