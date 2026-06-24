const std = @import("std");

pub const numz = @import("numz");
pub const bullet = @import("bullet.zig");
pub const net = @import("net.zig");
pub const PlanetKind = @import("planet.zig").PlanetKind;
pub const Planet = @import("planet.zig").Planet;
pub const StaticVertex = @import("vertex.zig").StaticVertex;
pub const SkinnedVertex = @import("vertex.zig").SkinnedVertex;

pub const Watcher = @import("watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
pub const AssetServer = @import("AssetServer.zig");
pub const SteamNet = @import("SteamNet.zig");

pub const Teleporter = struct {
    pub const intertact_distance: f32 = 6;
    pub const charge_distance: f32 = 12;

    id: u32 = 0,
    active: bool = false,
    charged: f32 = 0,
    max_charge: f32 = 100,
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
    };
    pub const State = enum(u16) {
        idle,
        walk,
        attack,
    };
};
