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
    pub const Kind = enum(u16) {
        unknown,
        player,
        planet,
        enemy,
        bullet,

        pub fn expectsModel(kind: Kind) bool {
            return switch (kind) {
                .player, .planet, .enemy => true,
                .unknown, .bullet => false,
            };
        }
    };
    pub const State = enum(u16) {
        idle,
        walk,
        attack,
    };
};
