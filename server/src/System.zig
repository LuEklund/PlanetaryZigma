const System = @This();

const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const director = @import("gameplay/director.zig");
const enemies = @import("gameplay/enemies.zig");
const items = @import("gameplay/items.zig");
const players = @import("gameplay/players.zig");
const projectiles = @import("gameplay/projectiles.zig");
const stage = @import("gameplay/stage.zig");
const teleporter = @import("gameplay/teleporter.zig");
const lobby = @import("gameplay/lobby.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
pub const Physics = @import("system/Physics.zig");
pub const Navmesh = @import("system/Navmesh.zig");
const PlayerController = @import("gameplay/PlayerController.zig");
const build_options = @import("build_options");

pub const Viewer = if (build_options.viewer) @import("viewer/Viewer.zig") else void;
pub const Window = @import("system_contract.zig").Window;

pub const World = @import("World.zig");
pub const Entity = World.Entity;

pub const Camera = World.Camera;
pub const Controller = World.Controller;

pub const std_options: std.Options = .{ .logFn = shared.logFn };

gpa: std.mem.Allocator,
io: std.Io,
world: World,
clock: shared.Clock,
network_manager: NetworkManager,
physics: Physics,
request_exit: bool,
viewer: Viewer,

pub const Data = @import("system_contract.zig").Data;

pub fn init(self: *System, data: *const Data) !void {
    shared.log_io = data.io;
    self.gpa = data.gpa;
    self.io = data.io;
    self.world = try .init(data.gpa, data.dev_mode);
    errdefer self.world.deinit(data.gpa);
    self.clock = .init(data.io);
    self.request_exit = false;
    try self.network_manager.init(data.gpa, data.io, data.mode, data.host_steam_id, data.log_connection_status);
    errdefer self.network_manager.deinit() catch {};
    self.physics = .init();
    errdefer self.physics.deinit();
    self.viewer = undefined;
    if (build_options.viewer) try self.viewer.init(data.gpa, data.io, data.window, self.world.planet.radiusFloat());
    errdefer if (build_options.viewer) self.viewer.deinit(self.gpa, self.io);

    try stage.loadPlace(&self.world, data.gpa, &self.physics, .ship);
}

pub fn deinit(self: *System) !void {
    if (build_options.viewer) self.viewer.deinit(self.gpa, self.io);
    self.physics.deinit();
    try self.network_manager.deinit();
    self.world.deinit(self.gpa);
}

pub fn update(self: *System) !void {
    if (!self.clock.stepDue(self.io, shared.tick_seconds)) return;
    const world = &self.world;
    world.tick += 1;
    world.elapsed_time += shared.tick_seconds;
    world.delta_time = shared.tick_seconds;
    try self.step(world);
}

fn step(self: *System, world: *World) !void {
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
        try stage.loadPlace(world, self.gpa, &self.physics, .planet);
    }
    if (world.start_round_requested) {
        world.start_round_requested = false;
        try stage.loadPlace(world, self.gpa, &self.physics, .planet);
    }
    if (world.go_again_requested) {
        world.go_again_requested = false;
        try players.updateWipe(world, self.gpa, &self.physics);
    }

    try PlayerController.update(world, &self.physics);
    lobby.updateLobby(world);
    if (world.place == .planet) try enemies.updateEnemies(world, &self.physics);
    if (world.place == .planet) director.updateRunTimer(world);
    if (world.place == .planet) try director.updateDirector(world);
    try self.physics.update(world);
    projectiles.updateProjectiles(world);
    try items.updateItems(world);
    if (world.place == .planet) teleporter.updateTeleporter(world);
    players.playerRegen(world);
    try world.flush(&self.physics);

    var anchor_buffer: [shared.max_players]nz.Vec3(f32) = undefined;
    var anchor_count: usize = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        anchor_buffer[anchor_count] = player.transform.position;
        anchor_count += 1;
    }
    try world.planet.update(self.gpa, anchor_buffer[0..anchor_count], Navmesh.nav_reach);
    try world.navmesh.update(world, self.gpa);
    if (build_options.viewer) {
        if (try self.viewer.draw(world, self.gpa, self.io)) self.request_exit = true;
    }
}

fn reload(self: *System, pre_reload: bool) !void {
    if (!pre_reload) shared.log_io = self.io;
    if (pre_reload) {
        if (self.world.navmesh.worker) |thread| {
            thread.join();
            self.world.navmesh.worker = null;
        }
    }
    try self.physics.reload(pre_reload, &self.world);
}

comptime {
    _ = ffi;
}

const layout_hash = shared.layout.hash(&.{ System, World });

pub const ffi = struct {
    pub export fn layoutHash() u64 {
        return layout_hash;
    }

    pub export fn systemInit(data: *const Data) ?*anyopaque {
        std.log.info("system init", .{});
        const system = data.gpa.create(System) catch return null;
        system.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system init: {s}", .{@errorName(err)});
            data.gpa.destroy(system);
            return null;
        };
        return system;
    }

    pub export fn systemDeinit(handle: *anyopaque) void {
        std.log.info("system deinit", .{});
        const system: *System = @ptrCast(@alignCast(handle));
        const gpa = system.gpa;
        system.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system deinit: {s}", .{@errorName(err)});
        };
        gpa.destroy(system);
    }

    pub export fn systemUpdate(handle: *anyopaque) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const system: *System = @ptrCast(@alignCast(handle));
        system.update() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system update: {s}", .{@errorName(err)});
        };
        return system.request_exit;
    }

    pub export fn reload(handle: *anyopaque, pre_reload: bool) void {
        const system: *System = @ptrCast(@alignCast(handle));
        system.reload(pre_reload) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system reload: {s}", .{@errorName(err)});
        };
    }
};
