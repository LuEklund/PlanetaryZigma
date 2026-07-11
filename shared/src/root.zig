const std = @import("std");

pub const numz = @import("numz");
pub const net = @import("net.zig");
pub const PlanetKind = @import("planet.zig").PlanetKind;
pub const Planet = @import("planet.zig").Planet;
pub const planetSdf = @import("planet.zig").sdf;
pub const StaticVertex = @import("vertex.zig").StaticVertex;
pub const SkinnedVertex = @import("vertex.zig").SkinnedVertex;

pub const Watcher = @import("Watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
pub const AssetServer = @import("AssetServer.zig");
pub const SteamNet = @import("SteamNet.zig");

pub const tick_seconds: f32 = 0.0167;

pub const teleporter = struct {
    pub const intertact_distance: f32 = 6;
    pub const charge_distance: f32 = 12;

    pub const State = struct {
        active: bool = false,
        charged: f32 = 0,
        max_charge: f32 = 100,
    };
};

const stats = @import("stats.zig");
pub const Stat = stats.Stat;
pub const Stats = stats.Stats;

const inventory = @import("inventory.zig");
pub const Item = inventory.Item;
pub const Inventory = inventory.Inventory;

pub const Entity = @import("Entity.zig");
