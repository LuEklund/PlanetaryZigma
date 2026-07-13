const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const ItemManager = @import("system/ItemManager.zig");
const Spawner = @import("system/Spawner.zig");
const EnemyManager = @import("system/EnemyManager.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");
const BulletManager = @import("system/BulletManager.zig");

pub const World = @import("system/World.zig");
pub const Entity = World.Entity;
pub const Camera = World.Camera;
pub const Controller = World.Controller;
pub const BulletData = World.BulletData;

pub const Info = struct {
    tick: u32,
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    world: *World,
    steam_server: *shared.SteamNet.Server,
    network_manager: NetworkManager,
    spawner: Spawner,
    physics: Physics,
    request_exit: bool,

    pub const Data = struct {
        gpa: std.mem.Allocator,
        world: *World,
        io: std.Io,
        steam_server: *shared.SteamNet.Server,
    };

    pub fn init(self: *Context, data: *const Data) !void {
        self.* = .{
            .gpa = data.gpa,
            .io = data.io,
            .world = data.world,
            .steam_server = data.steam_server,
            .network_manager = try .init(data.gpa, data.io, data.steam_server),
            .physics = .init(data.gpa, data.io),
            .spawner = .{},
            .request_exit = false,
        };

        // TODO: Move somewhere smarter when know how to move stages.
        try self.spawner.startStage(self.world, &self.physics);
    }

    pub fn deinit(self: *Context) !void {
        self.physics.deinit();
        try self.network_manager.deinit();
    }

    pub fn update(self: *Context, info: *const Info) !void {
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
        try EnemyManager.update(info);
        try self.spawner.update(info, &self.physics);
        try self.physics.update(info);
        try BulletManager.update(info, &self.physics);
        try ItemManager.update(info);
        self.teleporterCharge(info);
        try self.world.flush(&self.physics);
    }

    fn teleporterCharge(self: *Context, info: *const Info) void {
        const entity = self.world.getPtr(self.world.teleporter_id) orelse return;
        const teleporter = &entity.teleporter;
        if (teleporter.charged == teleporter.max_charge) {
            self.spawner.should_spawm = false;
            return;
        }
        for (self.world.players.items) |player_id| {
            const player = self.world.getPtr(player_id) orelse continue;
            if (teleporter.active and nz.vec.distance(player.transform.position, entity.transform.position) < shared.teleporter.charge_distance) {
                teleporter.charged += info.delta_time + 100;
                teleporter.charged = @min(teleporter.charged, teleporter.max_charge);
            }
        }
        self.world.outbox.appendAssumeCapacity(.{ .event = .{ .teleporter_charge = @floatCast(teleporter.charged) } });
    }

    fn reload(self: *Context, pre_reload: bool) !void {
        std.log.debug("before-1", .{});
        try self.physics.reload(pre_reload, self.world);
        try self.network_manager.reload(pre_reload);
        std.log.debug("before-0", .{});
    }
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemContextInit: *const fn (*Context, data: *const Context.Data) callconv(.c) void,
        systemContextDeinit: *const fn (*Context) callconv(.c) void,
        systemContextUpdate: *const fn (*Context, data: *const Info) callconv(.c) void,
        systemContextReload: *const fn (*Context, pre_reload: bool) callconv(.c) void,

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

    pub export fn systemContextInit(context: *Context, data: *const Context.Data) void {
        std.log.debug("system context init", .{});
        context.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        std.log.debug("system context deinit", .{});
        context.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = context.update(info);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
    pub export fn systemContextReload(context: *Context, pre_reload: bool) void {
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
};
