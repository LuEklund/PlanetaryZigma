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

pub const Entity = struct {
    pub const Stat = struct {
        pub const Kind = enum(u16) {
            health,
            speed,
            damage,
            attack_speed,
        };
        current: f32 = 0,
        base_max: f32 = 0,
        max: f32 = 0,
    };

    pub const Inventory = struct {
        internal_stats: std.EnumMap(Stat.Kind, Stat) = .initFull(.{}),
        internal_items: std.EnumMap(Stat.Kind, u8) = .initFull(0),

        fn getPtrItem(self: *@This(), stat_kind: Stat.Kind) *u8 {
            return self.internal_items.getPtr(stat_kind).?;
        }

        fn getPtrStat(self: *@This(), stat_kind: Stat.Kind) *Stat {
            return self.internal_stats.getPtr(stat_kind).?;
        }

        fn setStat(self: *@This(), stat_kind: Stat.Kind, stat: Stat) void {
            const stat_ptr = self.getPtrStat(stat_kind);
            stat_ptr.* = stat;
        }

        pub fn getAttackSpeed(self: *@This()) f32 {
            const stat = self.getStat(.attack_speed);
            return 1 / stat.current;
        }

        pub fn getStat(self: *const @This(), stat_kind: Stat.Kind) Stat {
            return self.internal_stats.get(stat_kind).?;
        }

        pub fn getItem(self: *const @This(), stat_kind: Stat.Kind) u8 {
            return self.internal_items.get(stat_kind).?;
        }

        pub fn addItem(self: *@This(), stat_kind: Stat.Kind, delta: u8) u8 {
            const count = self.getPtrItem(stat_kind);
            count.* += delta;
            self.updateStatMax(stat_kind);
            const stat = self.getPtrStat(stat_kind);
            const amount = getItemValue(stat_kind);
            stat.*.current += amount * delta;

            return count.*;
        }

        pub fn setItem(self: *@This(), stat_kind: Stat.Kind, count: u8) void {
            self.getPtrItem(stat_kind).* = count;
            self.updateStatMax(stat_kind);
        }

        pub fn addCurrent(self: *@This(), stat_kind: Stat.Kind, delta: f32) f32 {
            const stat = self.getPtrStat(stat_kind);
            stat.current += delta;
            return stat.current;
        }

        pub fn setCurrent(self: *@This(), stat_kind: Stat.Kind, value: f32) void {
            self.getPtrStat(stat_kind).current = value;
        }

        pub fn setMax(self: *@This(), stat_kind: Stat.Kind, value: f32) void {
            self.getPtrStat(stat_kind).max = value;
        }

        fn updateStatMax(self: *@This(), stat_kind: Stat.Kind) void {
            const items = self.getPtrItem(stat_kind);
            const stat = self.getPtrStat(stat_kind);
            const amount = getItemValue(stat_kind);
            stat.*.max = stat.*.base_max + amount * items.*;
        }

        pub fn initCombat(self: *@This(), health: f32, speed: f32, damage: f32, attack_speed: f32) void {
            self.setStat(.health, .{ .current = health, .base_max = health, .max = health });
            self.setStat(.speed, .{ .current = speed, .base_max = speed, .max = speed });
            self.setStat(.damage, .{ .current = damage, .base_max = damage, .max = damage });
            self.setStat(.attack_speed, .{ .current = attack_speed, .base_max = attack_speed, .max = attack_speed });
        }
    };

    pub fn getItemValue(stat_kind: Stat.Kind) f32 {
        return switch (stat_kind) {
            .health => 10,
            .speed => 1,
            .damage => 1,
            .attack_speed => 0.2,
        };
    }

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

        pub fn toStat(kind: Kind) ?Stat.Kind {
            return switch (kind) {
                .health_item => .health,
                .speed_item => .speed,
                .damage_item => .damage,
                .attack_speed_item => .attack_speed,
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
