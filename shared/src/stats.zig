const std = @import("std");
const inventory = @import("inventory.zig");
const Item = inventory.Item;
const Inventory = inventory.Inventory;

pub const Stat = struct {
    pub const Kind = enum(u16) {
        health = 0,
        speed = 1,
        damage = 2,
        attack_speed = 3,
        range = 4,
    };

    current: f32 = 0,
    base_max: f32 = 0,
    max: f32 = 0,
};

pub const Stats = struct {
    map: std.EnumMap(Stat.Kind, Stat) = .initFull(.{}),

    fn getPtr(self: *Stats, kind: Stat.Kind) *Stat {
        return self.map.getPtr(kind).?;
    }

    pub fn get(self: *const Stats, kind: Stat.Kind) Stat {
        return self.map.get(kind).?;
    }

    pub fn attackSpeed(self: *const Stats) f32 {
        return 1 / self.get(.attack_speed).current;
    }

    pub fn setCurrent(self: *Stats, kind: Stat.Kind, value: f32) void {
        self.getPtr(kind).current = value;
    }

    pub fn setMax(self: *Stats, kind: Stat.Kind, value: f32) void {
        self.getPtr(kind).max = value;
    }

    pub fn addCurrent(self: *Stats, kind: Stat.Kind, delta: f32) f32 {
        const stat = self.getPtr(kind);
        stat.current += delta;
        return stat.current;
    }

    pub fn init(self: *Stats, health: f32, speed: f32, damage: f32, attack_speed: f32, range: f32) void {
        self.map.put(.health, .{ .current = health, .base_max = health, .max = health });
        self.map.put(.speed, .{ .current = speed, .base_max = speed, .max = speed });
        self.map.put(.damage, .{ .current = damage, .base_max = damage, .max = damage });
        self.map.put(.attack_speed, .{ .current = attack_speed, .base_max = attack_speed, .max = attack_speed });
        self.map.put(.range, .{ .current = range, .base_max = range, .max = range });
    }

    pub fn gain(self: *Stats, item_kind: Item.Kind, amount: f32) void {
        const attributes = item_kind.getAttributeValues();
        for (std.enums.values(Stat.Kind)) |kind| {
            self.getPtr(kind).current += attributes.get(kind) * amount;
        }
    }

    pub fn refresh(self: *Stats, inv: Inventory) void {
        for (std.enums.values(Stat.Kind)) |kind| {
            var total: f32 = 0;
            for (std.enums.values(Item.Kind)) |item_kind| {
                total += item_kind.getAttributeValues().get(kind) * @as(f32, @floatFromInt(inv.get(item_kind)));
            }
            self.getPtr(kind).max = self.get(kind).base_max + total;
        }
    }
};
