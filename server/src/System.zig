const System = @This();

const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const gameplay = @import("system/gameplay.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");

pub const World = @import("World.zig");
pub const Entity = World.Entity;
pub const Camera = World.Camera;
pub const Controller = World.Controller;

pub const Info = struct {
    tick: u32,
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

gpa: std.mem.Allocator,
io: std.Io,
world: *World,
steam_server: *shared.SteamNet.Server,
network_manager: NetworkManager,
physics: Physics,
request_exit: bool,

pub const Data = struct {
    gpa: std.mem.Allocator,
    world: *World,
    io: std.Io,
    steam_server: *shared.SteamNet.Server,
};

pub fn init(self: *System, data: *const Data) !void {
    self.* = .{
        .gpa = data.gpa,
        .io = data.io,
        .world = data.world,
        .steam_server = data.steam_server,
        .network_manager = try .init(data.gpa, data.io, data.steam_server),
        .physics = .init(data.gpa, data.io),
        .request_exit = false,
    };

    try self.world.loadPlace(.ship, &self.physics);
}

pub fn deinit(self: *System) !void {
    self.physics.deinit();
    try self.network_manager.deinit();
}

pub fn update(self: *System, info: *const Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    switch (try self.network_manager.update(info)) {
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
    try PlayerController.update(info, &self.physics);
    if (self.world.place == .planet) try gameplay.updateEnemies(info);
    if (self.world.next_stage_requested) {
        self.world.next_stage_requested = false;
        try self.world.loadPlace(.planet, &self.physics);
    }
    if (self.world.start_round_requested) {
        self.world.start_round_requested = false;
        try self.world.loadPlace(.planet, &self.physics);
    }
    if (self.world.place == .planet) try gameplay.updateDirector(info);
    try self.physics.update(info);
    gameplay.updateProjectiles(info, &self.physics);
    try gameplay.updateItems(info);
    if (self.world.place == .planet) gameplay.updateTeleporter(info);
    gameplay.updateLifetimes(info);
    gameplay.playerRegen(info);
    try self.world.flush(&self.physics);
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
        systemUpdate: *const fn (*System, data: *const Info) callconv(.c) void,
        systemReload: *const fn (*System, pre_reload: bool) callconv(.c) void,

        pub fn load(dynlib: *shared.DynLib) !Table {
            var self: Table = undefined;
            inline for (std.meta.fields(Table)) |field| {
                std.log.debug("Looking up symbol: {s}", .{field.name});
                const ptr = dynlib.lookup(field.type, field.name);
                if (ptr) |p| {
                    @field(self, field.name) = p;
                } else {
                    std.log.err("Failed to lookup symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                }
            }
            return self;
        }
    };

    pub export fn systemInit(system: *System, data: *const Data) void {
        std.log.debug("system init", .{});
        system.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemDeinit(system: *System) void {
        std.log.debug("system deinit", .{});
        system.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("system deinit: {s}", .{@errorName(err)});
            return;
        };
        system.* = undefined;
    }

    pub export fn systemUpdate(system: *System, info: *const Info) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = system.update(info);
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
