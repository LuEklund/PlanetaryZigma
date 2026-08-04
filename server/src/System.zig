const System = @This();

const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const gameplay = @import("system/gameplay.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");
const Window = @import("Window");
const extract = @import("system/extract.zig");
const Observer = @import("system/Observer.zig");
const pause = @import("system/pause.zig");
const Ui = @import("render").Ui;
pub const AssetServer = @import("render").AssetServer;
pub const Backend = @import("render").Backend;
const Rendering = @import("render").Rendering;

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
/// Only present under --render. A dedicated server leaves this null, never opens a
/// window, and never dlopens render.so.
rendering: ?Rendering,
observer: Observer,
ui: Ui,
paused: bool,

pub const Data = struct {
    gpa: std.mem.Allocator,
    world: *World,
    io: std.Io,
    steam_server: *shared.SteamNet.Server,
    window: ?*Window,
    asset_server: ?*AssetServer,
};

pub fn init(self: *System, data: *const Data) !void {
    shared.log_io = data.io;
    self.* = .{
        .gpa = data.gpa,
        .io = data.io,
        .world = data.world,
        .steam_server = data.steam_server,
        .network_manager = try .init(data.gpa, data.io, data.steam_server),
        .physics = .init(data.gpa, data.io),
        .request_exit = false,
        .rendering = null,
        .observer = .init(.{ 0, data.world.planet_radius * World.ship_room_altitude_factor, 30 }),
        .ui = undefined,
        .paused = false,
    };

    if (data.window) |window| {
        self.rendering = undefined;
        try self.rendering.?.init(.{
            .gpa = data.gpa,
            .io = data.io,
            .window = window,
            .asset_server = data.asset_server.?,
        });
        self.ui = try .init(data.gpa, window.size.width, window.size.height);
        self.ui.default_font = &self.rendering.?.fonts[0];
        self.ui.texture_slots = &self.rendering.?.texture_slots;
    }

    try self.world.loadPlace(.ship, &self.physics);
}

pub fn deinit(self: *System) !void {
    if (self.rendering) |*rendering| {
        self.ui.deinit(self.gpa);
        rendering.deinit(self.gpa, self.io);
    }
    self.physics.deinit();
    try self.network_manager.deinit();
}

fn draw(self: *System, world: *World) !void {
    if (self.rendering == null) return;
    const rendering = &self.rendering.?;
    const window = rendering.window;
    try window.poll(.{ .text = null });

    if (window.keyboard.get(.escape) == .press) self.paused = !self.paused;
    if (self.paused or !window.focused) {
        try window.setPointerRelative(false);
        try window.setPointerConstraint(.none);
        try window.setPointerVisible(true);
    } else {
        try window.setPointerVisible(false);
        try window.setPointerConstraint(.locked);
        try window.setPointerRelative(true);
        self.observer.update(window, world.delta_time, world.players.items.len);
    }

    self.ui.screen_width = @floatFromInt(window.size.width);
    self.ui.screen_heigth = @floatFromInt(window.size.height);
    const pointer_position = switch (window.pointer.movement) {
        .position => |position| [2]f32{ @floatCast(position.x), @floatCast(position.y) },
        .relative => [2]f32{ 0, 0 },
    };
    self.ui.start(.{
        .position = .{ .left = pointer_position[0], .top = pointer_position[1] },
        .left_click = window.pointer.buttons.left,
        .right_click = window.pointer.buttons.right,
    }, world.delta_time);
    if (self.paused) switch (pause.update(&self.ui, world.players.items.len, self.observer.follow)) {
        .none => {},
        .resume_view => self.paused = false,
        .quit => self.request_exit = true,
    };
    self.ui.end();

    try extract.frame(world, rendering, self.observer, &self.ui);
    try rendering.reloadIfChanged(self.io);
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
    try self.physics.reload(pre_reload, self.world);
}

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemInit: *const fn (*System, data: *const Data) callconv(.c) void,
        systemDeinit: *const fn (*System) callconv(.c) void,
        systemUpdate: *const fn (*System, world: *World) callconv(.c) void,
        systemReload: *const fn (*System, pre_reload: bool) callconv(.c) void,
    };

    pub export fn systemInit(system: *System, data: *const Data) void {
        std.log.info("system init", .{});
        system.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system init: {s}", .{@errorName(err)});
            return;
        };
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
