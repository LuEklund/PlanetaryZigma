const Stats = @This();

const std = @import("std");
const inventory = @import("inventory.zig");
const Item = inventory.Item;
const Inventory = inventory.Inventory;

pub const Values = std.EnumArray(Kind, f32);

current: Values,
base_max: Values,
max: Values,

pub const Kind = enum(u16) {
    health = 0,
    speed = 1,
    damage = 2,
    attack_speed = 3,
    range = 4,
    regen = 5,
    rocket_chance = 6,
    lightning_chance = 7,
};

pub fn init(base: Values) Stats {
    return .{ .current = base, .base_max = base, .max = base };
}

pub fn attackSpeed(self: Stats) f32 {
    return 1 / self.current.get(.attack_speed);
}

pub fn addCurrent(self: *Stats, kind: Kind, delta: f32) f32 {
    const value = @min(self.max.get(kind), self.current.get(kind) + delta);
    self.current.set(kind, value);
    return value;
}

pub fn gain(self: *Stats, item_kind: Item, amount: f32) void {
    const attributes = item_kind.attributes();
    for (std.enums.values(Kind)) |kind| {
        self.current.set(kind, self.current.get(kind) + attributes.get(kind) * amount);
    }
}

pub fn refresh(self: *Stats, inv: Inventory) void {
    for (std.enums.values(Kind)) |kind| {
        var total: f32 = 0;
        for (std.enums.values(Item)) |item_kind| {
            total += item_kind.attributes().get(kind) * @as(f32, @floatFromInt(inv.get(item_kind)));
        }
        self.max.set(kind, self.base_max.get(kind) + total);
    }
}

test "item stacks raise max through the shared Kind list" {
    var player_stats: Stats = .init(.initDefault(0, .{ .health = 100, .damage = 1 }));
    try std.testing.expectEqual(@as(f32, 100), player_stats.max.get(.health));
    try std.testing.expectEqual(@as(f32, 0), player_stats.max.get(.rocket_chance));

    var inv: Inventory = .{};
    _ = inv.add(.oxygen_tank, 2);
    _ = inv.add(.rocket, 3);
    player_stats.refresh(inv);
    try std.testing.expectEqual(@as(f32, 120), player_stats.max.get(.health));
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), player_stats.max.get(.rocket_chance), 0.0001);
}
