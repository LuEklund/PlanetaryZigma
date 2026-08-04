const System = @This();

const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const gameplay = @import("system/gameplay.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");
const build_options = @import("build_options");

/// `void` in a dedicated build: no render package, no windowing, no Vulkan compiled in.
/// Every use below sits behind the same `build_options.render` check.
pub const Viewer = if (build_options.render) @import("system/Viewer.zig") else void;
pub const Window = if (build_options.render) @import("Window") else void;
pub const AssetServer = if (build_options.render) @import("render").AssetServer else void;

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
    window: if (build_options.render) *Window else void,
    asset_server: if (build_options.render) *AssetServer else void,
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
    self.viewer = undefined;
    if (build_options.render) try self.viewer.init(data.gpa, data.io, data.window, data.asset_server, data.world);
    errdefer if (build_options.render) self.viewer.deinit(self.gpa, self.io);

    try self.world.loadPlace(.ship, &self.physics);
}

pub fn deinit(self: *System) !void {
    if (build_options.render) self.viewer.deinit(self.gpa, self.io);
    self.physics.deinit();
    try self.network_manager.deinit();
}

fn draw(self: *System, world: *World) !void {
    if (!build_options.render) return;
    if (try self.viewer.draw(world, self.io)) self.request_exit = true;
}

pub fn update(self: *System, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

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
    if (self.world.next_stage_requested) {
        self.world.next_stage_requested = false;
        try self.world.loadPlace(.planet, &self.physics);
    }
    if (self.world.start_round_requested) {
        self.world.start_round_requested = false;
        try self.world.loadPlace(.planet, &self.physics);
    }
    if (self.world.go_again_requested) {
        self.world.go_again_requested = false;
        try gameplay.updateWipe(world, &self.physics);
    }

    try PlayerController.update(world, &self.physics);
    if (self.world.place == .planet) try gameplay.updateEnemies(world);
    if (self.world.place == .planet) try gameplay.updateDirector(world);
    try self.physics.update(world);
    gameplay.updateProjectiles(world, &self.physics);
    try gameplay.updateItems(world);
    if (self.world.place == .planet) gameplay.updateTeleporter(world);
    gameplay.updateLifetimes(world);
    gameplay.playerRegen(world);
    try self.world.flush(&self.physics);
    try self.draw(world);
}

fn reload(self: *System, pre_reload: bool) !void {
    // The fresh .so has its own copy of shared's globals, so without this every log
    // line after a swap comes out of a null io and loses its timestamp.
    if (!pre_reload) shared.log_io = self.io;
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
