const System = @This();

const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const gameplay = @import("system/gameplay.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
pub const Physics = @import("system/Physics.zig");
pub const Navmesh = @import("system/Navmesh.zig");
const PlayerController = @import("system/PlayerController.zig");
const build_options = @import("build_options");

/// `void` in a dedicated build: no render package, no windowing, no Vulkan compiled in.
pub const Viewer = if (build_options.viewer) @import("viewer/Viewer.zig") else void;
pub const Window = if (build_options.viewer) @import("Window") else void;
pub const AssetServer = if (build_options.viewer) @import("assets").AssetServer else void;

pub const World = @import("World.zig");
pub const Entity = World.Entity;

pub const Camera = World.Camera;
pub const Controller = World.Controller;

pub const std_options: std.Options = .{ .logFn = shared.logFn };

gpa: std.mem.Allocator,
io: std.Io,
world: *World,
steam_server: *shared.SteamNet.Server,
network_manager: NetworkManager,
physics: Physics,
request_exit: bool,
viewer: Viewer,

pub const Data = struct {
    gpa: std.mem.Allocator,
    world: *World,
    io: std.Io,
    steam_server: *shared.SteamNet.Server,
    window: if (build_options.viewer) *Window else void,
    asset_server: if (build_options.viewer) *AssetServer else void,
};

pub fn init(self: *System, data: *const Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.world = data.world;
    self.steam_server = data.steam_server;
    self.request_exit = false;
    self.network_manager = try .init(data.gpa, data.io, data.steam_server);
    errdefer self.network_manager.deinit() catch {};
    self.physics = .init(data.gpa, data.io);
    errdefer self.physics.deinit();
    data.world.physics = &self.physics;
    self.viewer = undefined;
    if (build_options.viewer) try self.viewer.init(data.gpa, data.io, data.window, data.asset_server, data.world.planet.radiusFloat());
    errdefer if (build_options.viewer) self.viewer.deinit(self.gpa, self.io);

    try data.world.loadPlace(.ship);
}

pub fn deinit(self: *System) !void {
    if (build_options.viewer) self.viewer.deinit(self.gpa, self.io);
    self.physics.deinit();
    try self.network_manager.deinit();
}

pub fn update(self: *System, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    world.planet.clearOutboxes();

    switch (try self.network_manager.update(world)) {
        .running => {},
        .host_left => {
            std.log.info("host disconnected, shutting down", .{});
            self.request_exit = true;
        },
        .host_timeout => {
            std.log.err("host never connected, shutting down", .{});
            self.request_exit = true;
        },
    }
    if (world.next_stage_requested) {
        world.next_stage_requested = false;
        try world.loadPlace(.planet);
    }
    if (world.start_round_requested) {
        world.start_round_requested = false;
        try world.loadPlace(.planet);
    }
    if (world.go_again_requested) {
        world.go_again_requested = false;
        try gameplay.updateWipe(world);
    }

    try PlayerController.update(world);
    if (world.place == .planet) try gameplay.updateEnemies(world);
    if (world.place == .planet) try gameplay.updateDirector(world);
    try self.physics.update(world);
    gameplay.updateProjectiles(world);
    try gameplay.updateItems(world);
    if (world.place == .planet) gameplay.updateTeleporter(world);
    gameplay.playerRegen(world);
    try world.flush();

    var anchor_buffer: [shared.max_players]nz.Vec3(f32) = undefined;
    var anchor_count: usize = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        if (player.flags.is_dead) continue;
        anchor_buffer[anchor_count] = player.transform.position;
        anchor_count += 1;
    }
    try world.planet.update(world.gpa, anchor_buffer[0..anchor_count], Navmesh.nav_reach);
    try world.navmesh.update(world);
    if (build_options.viewer) {
        if (try self.viewer.draw(world, self.io)) self.request_exit = true;
    }
}

fn reload(self: *System, pre_reload: bool) !void {
    // The fresh .so has its own copy of shared's globals, so without this every log
    // line after a swap comes out of a null io and loses its timestamp.
    if (!pre_reload) shared.log_io = self.io;
    if (pre_reload) {
        if (self.world.navmesh.worker) |thread| {
            thread.join();
            self.world.navmesh.worker = null;
        }
    }
    try self.physics.reload(pre_reload, self.world);
}

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemInit: *const fn (*System, data: *const Data) callconv(.c) bool,
        systemDeinit: *const fn (*System) callconv(.c) void,
        systemUpdate: *const fn (*System, world: *World) callconv(.c) void,
        systemReload: *const fn (*System, pre_reload: bool) callconv(.c) void,
    };

    pub export fn systemInit(system: *System, data: *const Data) bool {
        std.log.info("system init", .{});
        system.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system init: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub export fn systemDeinit(system: *System) void {
        std.log.info("system deinit", .{});
        system.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system deinit: {s}", .{@errorName(err)});
            return;
        };
        system.* = undefined;
    }

    pub export fn systemUpdate(system: *System, world: *World) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = system.update(world);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system update: {s}", .{@errorName(err)});
            return;
        };
    }
    pub export fn systemReload(system: *System, pre_reload: bool) void {
        const result = system.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system reload: {s}", .{@errorName(err)});
            return;
        };
    }
};
