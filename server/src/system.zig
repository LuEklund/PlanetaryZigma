const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const HealthManager = @import("system/HealthManager.zig");
const ItemManager = @import("system/ItemManager.zig");
const Spawner = @import("system/Spawner.zig");
const EnemyManager = @import("system/EnemyManager.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");
const CameraController = @import("system/CameraController.zig");
const Bullet = @import("system/Bullet.zig");

pub const Info = struct {
    tick: u64,
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Camera = struct {
    pub const Mode = enum { follow, free };

    mode: Mode = .follow,
    yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
    pitch: f32 = 0,
    boom_offset: nz.Vec3(f32) = .{ 0, 0, 0 },
    transform: nz.Transform3D(f32) = .{},
};

pub const Controller = struct {
    input: shared.net.Input = .{},
};

pub const BulletData = struct {
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    lifetime: f32 = 5,
};

pub const Entity = struct {
    id: u32 = 0,
    flags: Flags = .{},
    kind: shared.Entity.Kind = .unknown,
    owner_id: u32 = 0,

    transform: nz.Transform3D(f32) = .{},
    collider: Physics.Collider = undefined,
    controller: Controller = .{},
    camera: Camera = .{},
    bullet: BulletData = .{},
    health: HealthManager.Health = .{},
    attack_speed: f32 = 1,
    last_attack: f32 = 0,
    damage: f32 = 1,
    speed: f32 = 10,
    state: shared.Entity.State = .idle,
    item_amount: f32 = 0,

    pub const Flags = packed struct {
        transform: bool = false,
        collider: bool = false,
        controller: bool = false,
        camera: bool = false,
        bullet: bool = false,
        health: bool = false,
        invinsible: bool = false,
        item: bool = false,
        is_teleporter_boss: bool = false,
    };

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (self.flags.collider) {
            switch (self.collider.shape) {
                .mesh => |*mesh| {
                    gpa.free(mesh.indices);
                    gpa.free(mesh.vertices);
                },
                .primitive => {},
            }
        }
    }
};

pub const World = struct {
    pub const max_entities: usize = 1024;
    gpa: std.mem.Allocator,
    entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty,
    players: std.ArrayList(u32),
    portal_active: bool = false,
    teleportal_id: u32 = 0,
    planet_size: u32 = 100,

    next_id: u32 = 1,
    prng: std.Random.DefaultPrng = .init(0xACE1),

    pub fn init(gpa: std.mem.Allocator) !@This() {
        var entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty;
        try entities.ensureTotalCapacity(gpa, max_entities);

        return .{
            .gpa = gpa,
            .entities = entities,
            .players = try .initCapacity(gpa, 16),
        };
    }
    pub fn deinit(self: *@This()) void {
        for (self.entities.values()) |*entity| {
            entity.deinit(self.gpa);
        }
        self.entities.deinit(self.gpa);
    }

    pub fn spawn(self: *@This()) !*Entity {
        std.debug.assert(self.entities.entries.len < max_entities);
        const id = self.next_id;
        self.next_id += 1;
        self.entities.putAssumeCapacity(id, .{ .id = id });
        return self.entities.getPtr(id).?;
    }

    pub fn getPtr(self: *@This(), id: u32) ?*Entity {
        return self.entities.getPtr(id);
    }

    pub fn despawn(self: *@This(), id: u32) bool {
        if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
        if (std.mem.indexOfScalar(u32, self.players.items, id)) |i| {
            _ = self.players.swapRemove(i);
        }
        return self.entities.swapRemove(id);
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    world: *World,
    steam_server: *shared.SteamNet.Server,
    network_manager: NetworkManager,
    health_manager: HealthManager,
    physics: Physics,
    player_controller: PlayerController,
    camera_controller: CameraController,
    spawner: Spawner,
    enemy_manager: EnemyManager,
    item_manager: ItemManager,
    bullet: Bullet,
    request_exit: bool = false,

    pub const Data = struct {
        gpa: std.mem.Allocator,
        world: *World,
        io: std.Io,
        steam_server: *shared.SteamNet.Server,
    };

    pub fn init(self: *@This(), data: *const Data) !void {
        self.* = .{
            .gpa = data.gpa,
            .io = data.io,
            .world = data.world,
            .steam_server = data.steam_server,
            .spawner = undefined,
            .enemy_manager = undefined,
            .network_manager = undefined,
            .physics = undefined,
            .player_controller = undefined,
            .camera_controller = undefined,
            .bullet = undefined,
            .health_manager = undefined,
            .item_manager = undefined,
        };
        try self.physics.init(data.gpa, data.io);
        try self.player_controller.init(&self.physics, &self.spawner);
        try self.camera_controller.init();
        try self.spawner.init(data.gpa, data.world);
        try self.bullet.init(data.gpa, self.world, &self.physics);
        try self.enemy_manager.init(data.gpa, data.world);
        try self.network_manager.init(data.gpa, data.io, data.steam_server);
        try self.health_manager.init(&self.network_manager, &self.spawner);
        try self.item_manager.init();

        //TODO: Move somewhere smarter when know how to move stages.
        const info: Info = .{ .elapsed_time = 0, .world = self.world, .delta_time = 0, .tick = 0 };
        try self.spawner.update(&info, &self.physics, &self.network_manager);
        try self.spawner.spawnStrctures(self.world, &self.physics);
    }
    pub fn deinit(self: *@This()) !void {
        self.physics.deinit();
        try self.network_manager.deinit();
        try self.enemy_manager.deinit();
        self.bullet.deinit();
        self.spawner.deinit();
    }

    pub fn update(self: *@This(), info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        try self.network_manager.update(info, &self.spawner);
        try self.player_controller.update(info, &self.network_manager);
        try self.enemy_manager.update(info, &self.physics, &self.health_manager, &self.network_manager);
        try self.physics.update(info);
        try self.bullet.update(info, &self.health_manager, &self.spawner);
        try self.camera_controller.update(info);
        try self.spawner.update(info, &self.physics, &self.network_manager);
        try self.item_manager.update(info, &self.spawner, &self.health_manager);

        // std.log.debug("time : {d}", .{info.elapsed_time});
        // self.request_exit = true;
        // if (info.elapsed_time > 1) self.request_exit = true;
    }
    fn reload(self: *@This(), pre_reload: bool) !void {
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

        pub fn load(dynlib: *shared.DynLib) !@This() {
            var self: @This() = undefined;
            inline for (@typeInfo(@This()).@"struct".fields) |field| {
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
