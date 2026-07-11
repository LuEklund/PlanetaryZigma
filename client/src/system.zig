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
pub const Controller = @import("system/Controller.zig");
pub const Hud = @import("system/Hud.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Entity = struct {
    id: u32 = 0,
    kind: shared.Entity.Kind,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),

    transform: nz.Transform3D(f32) = .{},
};

pub const World = struct {
    pub const max_entities: usize = 1024;
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty,
    teleporter_bosses: std.ArrayList(u32) = .empty,
    camera: Camera = .{},
    controller: Controller = .{},
    hud: Hud = .{},
    teleporter_id: u32 = 0,
    player_id: u32 = 0,
    planet_radius: f32 = 0,

    pub fn init(gpa: std.mem.Allocator) !World {
        return .{
            .gpa = gpa,
            .teleporter_bosses = try .initCapacity(gpa, max_entities),
        };
    }
    pub fn deinit(self: *World) void {
        self.entities.deinit(self.gpa);
        self.teleporter_bosses.deinit(self.gpa);
    }

    pub fn spawn(self: *World, id: u32) !*Entity {
        try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
        return self.entities.getPtr(id).?;
    }

    pub fn getPtr(self: *World, id: u32) ?*Entity {
        return self.entities.getPtr(id);
    }

    pub fn despawn(self: *World, id: u32) bool {
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

    pub fn init(self: *Context, data: Data) !void {
        self.gpa = data.gpa;
        self.io = data.io;
        self.platform = data.platform;
        self.window = data.window;
        self.steam_client = data.steam_client;
        self.asset_server = data.asset_server;
        self.renderer = try .init(data.gpa, data.asset_server, data.platform, data.window);
        try self.spawner.init(data.gpa, data.world);
        try self.network_manager.init(data.gpa, data.io, data.steam_client, &self.spawner);
        self.animation = .init(data.gpa);
    }

    pub fn deinit(self: *Context) void {
        self.renderer.deinit(self.gpa);
        self.network_manager.deinit();
        self.spawner.deinit();
    }

    pub fn update(self: *Context, info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        // tracy.frameMark();
        info.world.controller.update();
        try info.world.hud.update(info, &self.network_manager, &self.renderer.inner.ui, &info.world.controller);
        try self.renderer.update(info);
        try self.animation.update(info, &self.renderer.inner.skeletons);
        try self.asset_server.update();
        try self.network_manager.update(info, &self.renderer.inner.skeletons);
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
        }

        info.world.camera.update(info);
        info.world.controller.mouse_wheel = 0;
        // std.log.debug("time : {d}", .{info.elapsed_time});
    }

    pub fn eventUpdate(self: *Context, info: *const Info, event: *const yes.Window.Event) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = self;
        info.world.controller.eventUpdate(event);
    }
    fn reload(self: *Context, pre_reload: bool) !void {
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

        pub fn load(dynlib: *shared.DynLib) !Table {
            var self: Table = undefined;
            inline for (std.meta.fields(Table)) |field| {
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
            std.debug.panic("context init: {s}", .{@errorName(err)});
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
            std.debug.panic("context update: {s}", .{@errorName(err)});
        };
    }

    pub export fn systemContextReload(context: *Context, pre_reload: bool) void {
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.debug.panic("context reload: {s}", .{@errorName(err)});
        };
    }
};
