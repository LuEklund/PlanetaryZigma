const std = @import("std");

pub const numz = @import("numz");
pub const camera = @import("camera.zig");
pub const net = @import("net.zig");
pub const PlanetKind = @import("planet.zig").PlanetKind;
pub const Planet = @import("planet.zig").Planet;
pub const StaticVertex = @import("vertex.zig").StaticVertex;
pub const SkinnedVertex = @import("vertex.zig").SkinnedVertex;

pub const Watcher = @import("watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
pub const AssetServer = @import("AssetServer.zig");
pub const SteamNet = @import("SteamNet.zig");

pub const tick_seconds: f32 = 0.0167;

pub const Teleporter = struct {
    pub const intertact_distance: f32 = 6;
    pub const charge_distance: f32 = 12;
};

pub const TeleporterState = struct {
    active: bool = false,
    charged: f32 = 0,
    max_charge: f32 = 100,
};

pub const StatKind = enum(u16) {
    health,
    speed,
    damage,
    attack_speed,
};

pub const Stat = struct {
    current: f32 = 0,
    base_max: f32 = 0,
    max: f32 = 0,
};

// A per-stat scalar bundle: one item's contribution can touch several stats at once.
pub const Stats = struct {
    health: f32 = 0,
    speed: f32 = 0,
    damage: f32 = 0,
    attack_speed: f32 = 0,

    pub fn get(self: Stats, stat_kind: StatKind) f32 {
        return switch (stat_kind) {
            .health => self.health,
            .speed => self.speed,
            .damage => self.damage,
            .attack_speed => self.attack_speed,
        };
    }
};

pub const ItemKind = enum(u16) {
    health_potion,
    speed_potion,
    damage_potion,
    attack_speed_potion,

    // One item can move multiple stats.
    pub fn stats(self: ItemKind) Stats {
        return switch (self) {
            .health_potion => .{ .health = 10 },
            .speed_potion => .{ .speed = 1 },
            .damage_potion => .{ .damage = 1 },
            .attack_speed_potion => .{ .attack_speed = 0.2 },
        };
    }
};

pub const Inventory = struct {
    stats: std.EnumMap(StatKind, Stat) = .initFull(.{}),
    items: std.EnumMap(ItemKind, u8) = .initFull(0),

    fn getPtrStat(self: *@This(), stat_kind: StatKind) *Stat {
        return self.stats.getPtr(stat_kind).?;
    }

    fn setStat(self: *@This(), stat_kind: StatKind, stat: Stat) void {
        self.getPtrStat(stat_kind).* = stat;
    }

    pub fn getStat(self: *const @This(), stat_kind: StatKind) Stat {
        return self.stats.get(stat_kind).?;
    }

    pub fn getItem(self: *const @This(), item_kind: ItemKind) u8 {
        return self.items.get(item_kind).?;
    }

    pub fn getAttackSpeed(self: *const @This()) f32 {
        return 1 / self.getStat(.attack_speed).current;
    }

    // Server: pick up an item — bump its count, apply its (multi-stat) contribution to current, refresh maxes.
    pub fn addItem(self: *@This(), item_kind: ItemKind, delta: u8) u8 {
        const count = self.items.getPtr(item_kind).?;
        count.* += delta;
        const contribution = item_kind.stats();
        for (std.enums.values(StatKind)) |stat_kind| {
            self.getPtrStat(stat_kind).current += contribution.get(stat_kind) * @as(f32, @floatFromInt(delta));
            self.updateStatMax(stat_kind);
        }
        return count.*;
    }

    // Client: mirror an authoritative item count. No local derivation — base_max is server-only.
    pub fn setItem(self: *@This(), item_kind: ItemKind, count: u8) void {
        self.items.getPtr(item_kind).?.* = count;
    }

    pub fn addCurrent(self: *@This(), stat_kind: StatKind, delta: f32) f32 {
        const stat = self.getPtrStat(stat_kind);
        stat.current += delta;
        return stat.current;
    }

    pub fn setCurrent(self: *@This(), stat_kind: StatKind, value: f32) void {
        self.getPtrStat(stat_kind).current = value;
    }

    pub fn setMax(self: *@This(), stat_kind: StatKind, value: f32) void {
        self.getPtrStat(stat_kind).max = value;
    }

    fn updateStatMax(self: *@This(), stat_kind: StatKind) void {
        var bonus: f32 = 0;
        for (std.enums.values(ItemKind)) |item_kind| {
            const count = self.items.get(item_kind).?;
            bonus += item_kind.stats().get(stat_kind) * @as(f32, @floatFromInt(count));
        }
        const stat = self.getPtrStat(stat_kind);
        stat.max = stat.base_max + bonus;
    }

    pub fn initCombat(self: *@This(), health: f32, speed: f32, damage: f32, attack_speed: f32) void {
        self.setStat(.health, .{ .current = health, .base_max = health, .max = health });
        self.setStat(.speed, .{ .current = speed, .base_max = speed, .max = speed });
        self.setStat(.damage, .{ .current = damage, .base_max = damage, .max = damage });
        self.setStat(.attack_speed, .{ .current = attack_speed, .base_max = attack_speed, .max = attack_speed });
    }
};

pub const Entity = struct {
    pub fn isEnemy(kind: Kind) bool {
        return switch (kind) {
            .skelly, .wizard => true,
            else => false,
        };
    }

    pub fn isItem(kind: Kind) bool {
        return switch (kind) {
            .health_item,
            .speed_item,
            .damage_item,
            .attack_speed_item,
            => true,
            else => false,
        };
    }

    pub fn hasCollider(kind: Kind) bool {
        return switch (kind) {
            .unknown, .bullet => false,
            else => true,
        };
    }

    pub fn hasHealth(kind: Kind) bool {
        return kind == .player or isEnemy(kind);
    }

    pub const Kind = enum(u16) {
        unknown,
        player,
        planet,
        bullet,

        teleporter,

        skelly,
        wizard,

        health_item,
        speed_item,
        damage_item,
        attack_speed_item,

        pub fn expectsModel(kind: Kind) bool {
            return switch (kind) {
                .player, .planet => true,
                .unknown, .bullet => false,
                else => isEnemy(kind) or isItem(kind),
            };
        }

        pub fn toItem(kind: Kind) ?ItemKind {
            return switch (kind) {
                .health_item => .health_potion,
                .speed_item => .speed_potion,
                .damage_item => .damage_potion,
                .attack_speed_item => .attack_speed_potion,
                else => null,
            };
        }
    };
    pub const State = enum(u16) {
        idle,
        walk,
        attack,
    };
};
