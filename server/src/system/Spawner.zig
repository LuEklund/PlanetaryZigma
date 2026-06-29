const std = @import("std");
const system = @import("../system.zig");
const Entity = system.Entity;
const shared = @import("shared");
const Physics = @import("Physics.zig");
const NetworkManager = @import("NetworkManager.zig");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;
const max_despawn_count: u32 = 1000;

gpa: std.mem.Allocator,
world: *system.World,
physics: *Physics,
network_manager: *NetworkManager,

credits: f32 = 0,
salary_per_second: f32 = 1,
last_salary: f32 = 0,
enemy_cost: f32 = 10,
should_spawm: bool = false,

pending_spawn: std.ArrayList(u32) = .empty,
pending_despawn: std.ArrayList(u32) = .empty,

pub fn init(
    self: *@This(),
    gpa: std.mem.Allocator,
    world: *system.World,
    physics: *Physics,
    network_manager: *NetworkManager,
) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .pending_despawn = try .initCapacity(gpa, max_despawn_count),
        .network_manager = network_manager,
        .physics = physics,
    };
}

pub fn deinit(self: *@This()) void {
    self.pending_despawn.deinit(self.gpa);
}

pub fn spawn(self: *@This(), entity_info: system.Entity) !*system.Entity {
    // std.log.debug("SIZE: {d}", .{self.world.entities.entries.len});
    const entity = try self.world.spawn();
    const id: u32 = entity.id;
    entity.* = entity_info;
    entity.id = id;
    try self.pending_spawn.append(self.gpa, id);
    if (entity.flags.is_teleporter_boss) self.world.teleport_bosses.appendAssumeCapacity(entity.id);
    try self.network_manager.pending_spawn.append(self.gpa, entity.id);
    if (shared.Entity.hasCollider(entity.kind)) {
        try self.physics.createBody(entity);
    }
    return entity;
}

pub fn depspawn(self: *@This(), entity_id: u32) void {
    // std.log.debug("despawn ID: {d}", .{entity_id});
    self.pending_despawn.appendAssumeCapacity(entity_id);
}

pub fn update(
    self: *@This(),
    info: *const system.Info,
    physics: *Physics,
    network_manager: *NetworkManager,
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (self.should_spawm and info.world.players.items.len != 0) {
        if (info.elapsed_time - self.last_salary >= 1.0) {
            self.last_salary = info.elapsed_time;
            self.credits += self.salary_per_second * 10;
        }
        const rand = info.world.prng.random();
        const x = rand.float(f32) * 2 - 1;
        const y = rand.float(f32) * 2 - 1;
        const z = rand.float(f32) * 2 - 1;
        const vector_direction: nz.Vec3(f32) = .{ x, y, z };
        if (self.credits >= self.enemy_cost) {
            self.credits -= self.enemy_cost;
            _ = try self.spawn(.{
                .kind = .skelly,
                .transform = .{ .position = vector_direction },
                .collider = .{
                    .shape = .{ .primitive = .{ .capsule = .{ .half_heigth = 0.8, .radius = 0.8 } } },
                    .motion_type = .dynamic,
                    .object_layer = .moving,
                },
                .health = .{ .current = 10, .max = 10 },
            });
        }
    }

    // for (self.pending_spawn.items) |entity_id| {
    //     const entity = info.world.entities.getPtr(entity_id) orelse @panic(" this can only happen if we remove enteties from other places than trough spawner,");
    //
    //
    // }
    // self.pending_spawn.clearRetainingCapacity();

    std.debug.assert(self.pending_despawn.items.len < max_despawn_count);
    for (self.pending_despawn.items) |entity_id| {
        if (self.world.getPtr(entity_id)) |entity| {
            if (shared.Entity.hasCollider(entity.kind)) {
                if (entity.collider.body_id) |body_id| physics.destroyBody(body_id);
                std.log.debug("DESTROYED body_id={any} for entity id={d} kind={s}", .{
                    entity.collider.body_id, entity.id, @tagName(entity.kind),
                });
            }
            if (std.mem.indexOfScalar(u32, info.world.teleport_bosses.items, entity_id)) |index_of_boss| {
                _ = info.world.teleport_bosses.swapRemove(index_of_boss);
            }
            if (!self.world.despawn(entity_id)) @panic("fack");
            try network_manager.pending_despawn.append(self.gpa, entity_id);
        }
    }
    self.pending_despawn.clearRetainingCapacity();
}

pub fn startStage(self: *@This(), world: *system.World, physics: *Physics) !void {
    const rand = world.prng.random();
    world.teleportal = .{};
    self.should_spawm = true;
    self.network_manager.pending_events.appendAssumeCapacity(.new_stage);
    world.planet_size = @intFromFloat(rand.float(f32) * 100 + 1);
    // world.planet_size = 50;
    const planet: shared.Planet(.logical) = try .init(self.gpa, world.planet_size);
    _ = try self.spawn(.{
        .kind = .planet,
        .transform = .{},
        .collider = .{
            .shape = .{
                .mesh = .{
                    .indices = planet.indices,
                    .vertices = planet.vertices,
                },
            },
            .motion_type = .static,
            .object_layer = .non_moving,
        },
    });

    for (0..20) |i| {
        const item_kind: shared.Entity.Kind = switch (i) {
            0...5 => .attack_speed_item,
            6...10 => .speed_item,
            11...15 => .damage_item,
            else => .health_item,
        };
        const vector_direction = nz.vec.randomUnitVector(nz.Vec3(f32), rand);
        _ = try self.spawn(.{
            .kind = item_kind,
            .transform = .{ .position = nz.vec.scale(vector_direction, 100) },
            .collider = .{
                .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
                .motion_type = .dynamic,
                .object_layer = .planet_only,
            },
            .item_amount = @floatFromInt(i + 1),
        });
    }

    var teleport_position: ?nz.Vec3(f32) = null;
    while (teleport_position == null) {
        teleport_position = physics.getSurfacePoint(world, .{ 0, 100, 0 });
    } else {
        const teleporter = try self.spawn(.{
            .kind = .teleporter,
            .transform = .{ .position = teleport_position.? },
            .collider = .{
                .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
                .motion_type = .static,
                .object_layer = .non_moving,
            },
        });
        const teleport_planet_up = nz.vec.normalize(teleport_position.?);
        const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
        const dot = std.math.clamp(nz.vec.dot(default_up, teleport_planet_up), -1.0, 1.0);
        teleporter.transform.rotation = if (dot < 0.9999) blk: {
            const axis = if (dot > -0.9999)
                nz.vec.normalize(nz.vec.cross(default_up, teleport_planet_up))
            else
                nz.Vec3(f32){ 1, 0, 0 };
            break :blk nz.quat.Hamiltonian(f32).angleAxis(std.math.acos(dot), axis);
        } else .identity;
        world.teleportal.id = teleporter.id;
    }
}
