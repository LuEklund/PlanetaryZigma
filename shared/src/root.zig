const std = @import("std");

pub const numz = @import("numz");
pub const net = @import("net.zig");
pub const PlanetKind = @import("planet.zig").PlanetKind;
pub const Planet = @import("planet.zig").Planet;

pub const Watcher = @import("watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
pub const AssetServer = @import("AssetServer.zig");
pub const SteamNet = @import("SteamNet.zig");

pub const Entity = struct {
    pub fn isEnemy(kind: Kind) bool {
        return switch (kind) {
            .skelly => true,
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

    pub const Kind = enum(u16) {
        unknown,
        player,
        planet,
        bullet,

        skelly,

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
