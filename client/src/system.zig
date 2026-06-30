const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const yes = @import("yes");
const NetworkManager = @import("system/NetworkManager.zig");
const AssetServer = @import("shared").AssetServer;
const Spawner = @import("system/Spawner.zig");
const Animation = @import("system/Animations.zig");
pub const Renderer = @import("Renderer.zig");

pub const Camera = @import("system/Camera.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Entity = struct {
    pub const Health = struct {
        current: f32 = 0,
        max: f32 = 1,
    };
    id: u32 = 0,
    kind: shared.Entity.Kind,
    state: shared.Entity.State = .walk,
    health: Health = .{},
    teleporter: shared.TeleporterState = .{},

    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),

    transform: nz.Transform3D(f32) = .{},
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }
    pub fn isEnemy(self: *Entity) bool {
        return shared.Entity.isEnemy(self.kind);
    }
    pub fn isItem(self: *Entity) bool {
        return shared.Entity.isItem(self.kind);
    }
};

pub const World = struct {
    pub const max_entities: usize = 1024;
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty,
    teleporter_bosses: std.ArrayList(u32) = .empty,
    camera: Camera = .{},
    teleporter_id: u32 = 0,
    player_id: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) !@This() {
        return .{
            .gpa = gpa,
            .teleporter_bosses = try .initCapacity(gpa, max_entities),
        };
    }
    pub fn deinit(self: *@This()) void {
        for (self.entities.values()) |*entity| entity.deinit(self.gpa);
        self.entities.deinit(self.gpa);
        self.teleporter_bosses.deinit(self.gpa);
    }

    pub fn spawn(self: *@This(), id: u32) !*Entity {
        try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
        return self.entities.getPtr(id).?;
    }

    pub fn getPtr(self: *@This(), id: u32) ?*Entity {
        return self.entities.getPtr(id);
    }

    pub fn despawn(self: *@This(), id: u32) bool {
        if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
        return self.entities.swapRemove(id);
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    platform: yes.Platform,
    window: *yes.Window,
    steam_client: *shared.SteamNet.Client,
    asset_server: *AssetServer,
    renderer: Renderer,
    network_manager: NetworkManager,
    spawner: Spawner,
    animation: Animation,

    pub const Data = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        platform: yes.Platform,
        window: *yes.Window,
        asset_server: *AssetServer,
        world: *World,
        steam_client: *shared.SteamNet.Client,
    };

    pub fn init(self: *@This(), data: Data) !void {
        self.gpa = data.gpa;
        self.io = data.io;
        self.platform = data.platform;
        self.window = data.window;
        self.steam_client = data.steam_client;
        self.asset_server = data.asset_server;
        self.renderer = try .init(data.gpa, data.asset_server, data.platform, data.window);
        try self.spawner.init(data.gpa, data.world);
        try self.network_manager.init(data.gpa, data.io, data.steam_client, &self.spawner);
        self.animation.init(data.gpa);
    }

    pub fn deinit(self: *@This()) void {
        self.renderer.deinit(self.gpa);
        self.network_manager.deinit();
        self.spawner.deinit();
    }

    pub fn update(self: *@This(), info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        // tracy.frameMark();
        try info.world.camera.update(info, &self.network_manager, &self.renderer.inner.ui);
        try self.renderer.update(info);
        try self.animation.update(info, &self.renderer.inner.skeletons);
        try self.asset_server.update();
        try self.network_manager.update(info, &self.renderer.inner.skeletons);
        self.stepBullets(info);
        try self.spawner.update(info, self);

        const server_time = self.network_manager.server_tick_estimate * shared.tick_seconds;
        for (info.world.entities.values()) |*entity| {
            const motion = entity.update_motion orelse continue;
            const motion_time = @as(f32, @floatFromInt(motion.tick)) * shared.tick_seconds;
            const age = server_time - motion_time;
            const target = motion.position + nz.vec.scale(motion.velocity, age);

            if (motion.tick != entity.smoothed_moiton_tick) {
                entity.position_error = entity.transform.position - target;
                entity.smoothed_moiton_tick = motion.tick;
            }

            const error_decay = std.math.pow(f32, 1e-5, info.delta_time);
            entity.position_error = nz.vec.scale(entity.position_error, error_decay);
            entity.transform.position = target + entity.position_error;

            const target_rotation = nz.Quat(f32).fromVec(motion.rotation);
            const rotation_decay = std.math.pow(f32, 1e-5, info.delta_time);
            entity.transform.rotation = entity.transform.rotation.slerp(target_rotation, 1.0 - rotation_decay);
            // entity.transform.rotation = nz.Quat(f32).fromVec(motion.rotation);
        }

        if (info.world.getPtr(info.world.player_id)) |player| {
            info.world.camera.applyPose(player.transform.position);
        }
        // std.log.debug("time : {d}", .{info.elapsed_time});
    }

    fn stepBullets(self: *@This(), info: *const Info) void {
        _ = self;
        for (info.world.entities.values()) |*entity| {
            if (entity.kind != .bullet) continue;
            shared.bullet.step(&entity.transform.position, &entity.velocity, info.delta_time);
        }
    }

    pub fn eventUpdate(self: *@This(), info: *const Info, event: *const yes.Window.Event) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = self;
        try info.world.camera.eventUpdate(info, event);
    }
    fn reload(self: *@This(), pre_reload: bool) !void {
        if (pre_reload) {
            std.log.debug("pre-hotreload", .{});
        } else {
            std.log.debug("post-hotreload", .{});
            self.renderer.inner.rebindProcs();
        }
    }
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemContextInit: *const fn (*Context, data: *const Context.Data) callconv(.c) void,
        systemContextDeinit: *const fn (*Context) callconv(.c) void,
        systemContextUpdate: *const fn (*Context, data: *const Info, event: ?*const yes.Window.Event) callconv(.c) void,
        systemContextReload: *const fn (*Context, pre_reload: bool) callconv(.c) void,

        pub fn load(dynlib: *shared.DynLib) !@This() {
            var self: @This() = undefined;
            inline for (@typeInfo(@This()).@"struct".fields) |field| {
                std.log.debug("Looking up symbol: {s}", .{field.name});
                const ptr = dynlib.lookup(field.type, field.name) orelse {
                    std.log.err("Failed to lookup symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                };
                @field(self, field.name) = ptr;
            }
            return self;
        }
    };

    pub export fn systemContextInit(context: *Context, data: *const Context.Data) void {
        std.log.debug("system context init", .{});
        context.init(data.*) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        std.log.debug("system context deinit", .{});
        context.deinit();
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info, event: ?*const yes.Window.Event) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = if (event != null) context.eventUpdate(info, event.?) else context.update(info);
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
