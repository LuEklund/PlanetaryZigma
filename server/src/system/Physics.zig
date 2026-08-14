const Physics = @This();

const std = @import("std");
const shared = @import("shared");
const World = @import("../World.zig");
const system = @import("../System.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

const c = @import("box3d");

pub const gravity_accel: f32 = 50;
const move_accel: f32 = 400;
const ground_friction: f32 = 10;
const ground_check_skin: f32 = 0.2;

const Category = struct {
    const non_moving: u64 = 1 << 0;
    const moving: u64 = 1 << 1;
    const planet_only: u64 = 1 << 2;
};

gpa: std.mem.Allocator,
io: std.Io,
world: c.b3WorldId,

pub const MotionType = shared.entity.MotionType;
pub const ObjectLayer = shared.entity.ObjectLayer;

fn layerFilter(layer: ObjectLayer) c.b3Filter {
    return switch (layer) {
        .non_moving => .{ .categoryBits = Category.non_moving, .maskBits = Category.moving | Category.planet_only, .groupIndex = 0 },
        .moving => .{ .categoryBits = Category.moving, .maskBits = Category.non_moving | Category.moving, .groupIndex = 0 },
        .planet_only => .{ .categoryBits = Category.planet_only, .maskBits = Category.non_moving, .groupIndex = 0 },
    };
}

pub const BodyId = c.b3BodyId;

fn toVec(v: c.b3Vec3) nz.Vec3(f32) {
    return .{ v.x, v.y, v.z };
}

fn toB3(v: nz.Vec3(f32)) c.b3Vec3 {
    return .{ .x = v[0], .y = v[1], .z = v[2] };
}

fn quatToB3(rotation: nz.quat.Hamiltonian(f32)) c.b3Quat {
    const q = rotation.toVec();
    return .{ .v = .{ .x = q[0], .y = q[1], .z = q[2] }, .s = q[3] };
}

fn quatFromB3(q: c.b3Quat) nz.quat.Hamiltonian(f32) {
    return .fromVec(.{ q.v.x, q.v.y, q.v.z, q.s });
}

fn makeWorld() c.b3WorldId {
    var world_def = c.b3DefaultWorldDef();
    world_def.gravity = .{ .x = 0, .y = 0, .z = 0 };
    return c.b3CreateWorld(&world_def);
}

pub fn init(gpa: std.mem.Allocator, io: std.Io) Physics {
    return .{
        .gpa = gpa,
        .io = io,
        .world = makeWorld(),
    };
}

pub fn deinit(self: *Physics) void {
    c.b3DestroyWorld(self.world);
}

pub fn reload(self: *Physics, pre_reload: bool, world: *system.World) !void {
    if (pre_reload) {
        c.b3DestroyWorld(self.world);
        self.world = undefined;
    } else {
        self.world = makeWorld();
        for (world.entities.values()) |*entity| entity.body_id = null;
        for (world.entities.values()) |*entity| {
            if (entity.kind.collider() == null) continue;
            if (entity.flags.is_dead) continue;
            try self.createBody(entity);
        }
    }
}

pub fn update(self: *Physics, world: *World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (world.physics_commands.items) |command| {
        const entity = world.getPtr(command.id) orelse continue;
        const body_id = entity.body_id orelse continue;
        switch (command.verb) {
            .walk => |walk| moveOnPlanet(entity, body_id, walk.direction, walk.speed, world.delta_time),
            .hover => |hover| floatOnPlanet(entity, body_id, hover.direction, hover.speed, &world.planet, hover.height, world.delta_time),
            .face => |direction| faceOnPlanet(entity, body_id, direction),
            .jump => |force| jump(entity, body_id, force),
            .arc_jump => |target| arcJumpTo(entity, body_id, target),
            .teleport => |position| setPosition(body_id, position),
            .set_velocity => |velocity| setLinearVelocity(body_id, velocity),
            .set_rotation => |rotation| setRotation(body_id, rotation),
        }
    }
    world.physics_commands.clearRetainingCapacity();

    for (world.entities.values()) |*entity| {
        const kind_collider = entity.kind.collider() orelse continue;
        const body_id = entity.body_id orelse continue;
        if (kind_collider.motion != .dynamic) continue;

        const distance_from_center = nz.vec.length(entity.transform.position);
        if (distance_from_center < 4) {
            const direction = nz.vec.randomUnitVector(nz.Vec3(f32), world.prng.random());
            var point = world.planet.surfacePoint(direction);
            point += nz.vec.scale(nz.vec.normalize(point), 5);
            c.b3Body_SetTransform(body_id, toB3(point), c.b3Body_GetRotation(body_id));
            c.b3Body_SetLinearVelocity(body_id, .{ .x = 0, .y = 0, .z = 0 });
            continue;
        }
        const planet_up = nz.vec.scale(entity.transform.position, 1.0 / distance_from_center);
        const radial_speed = nz.vec.dot(toVec(c.b3Body_GetLinearVelocity(body_id)), planet_up);
        switch (entity.mode) {
            .walking => if (!self.isGrounded(entity, &world.planet)) {
                entity.mode = .falling;
            },
            .falling => if (radial_speed <= 0 and self.isGrounded(entity, &world.planet)) {
                entity.mode = .walking;
            },
        }
        if (entity.mode == .falling) {
            const mass = c.b3Body_GetMass(body_id);
            c.b3Body_ApplyForceToCenter(body_id, toB3(nz.vec.scale(-planet_up, mass * gravity_accel)), true);
        }

        const body_up = entity.transform.up();
        const up_alignment_dot = std.math.clamp(nz.vec.dot(body_up, planet_up), -1.0, 1.0);
        if (up_alignment_dot < 0.9999) {
            const rotation_axis: nz.Vec3(f32) = if (up_alignment_dot > -0.9999)
                nz.vec.normalize(nz.vec.cross(body_up, planet_up))
            else
                nz.vec.normalize(nz.vec.cross(body_up, entity.transform.forward()));
            const upright_angle = std.math.acos(up_alignment_dot);
            const upright_rotation: nz.quat.Hamiltonian(f32) = .angleAxis(upright_angle, rotation_axis);
            entity.transform.rotation = upright_rotation.mul(entity.transform.rotation).normalize();
            c.b3Body_SetTransform(body_id, c.b3Body_GetPosition(body_id), quatToB3(entity.transform.rotation));
        }
    }

    c.b3World_Step(self.world, world.delta_time, 4);

    for (world.entities.values()) |*entity| {
        const body_id = entity.body_id orelse continue;

        const pos = c.b3Body_GetPosition(body_id);
        entity.transform.position = .{ pos.x, pos.y, pos.z };
        entity.transform.rotation = quatFromB3(c.b3Body_GetRotation(body_id));
        entity.replicated_velocity = toVec(c.b3Body_GetLinearVelocity(body_id));
    }

    for (world.entities.values()) |*entity| {
        const kind_collider = entity.kind.collider() orelse continue;
        const body_id = entity.body_id orelse continue;
        if (kind_collider.motion != .dynamic) continue;
        if (entity.mode == .falling and nz.vec.dot(entity.replicated_velocity, nz.vec.normalize(entity.transform.position)) > 0) continue;

        const clearance = colliderGroundExtent(kind_collider.shape);
        const value = world.planet.sample(entity.transform.position);
        if (value >= (clearance + ground_check_skin) * 2) continue;
        const gradient = sdfGradient(entity.transform.position, &world.planet);
        const gradient_length = nz.vec.length(gradient);
        const normal = if (gradient_length > 0.0001) nz.vec.scale(gradient, 1.0 / gradient_length) else nz.vec.normalize(entity.transform.position);
        const distance = if (gradient_length > 0.0001) value / gradient_length else value;
        if (distance >= clearance + ground_check_skin) continue;
        if (distance < clearance) {
            entity.transform.position += nz.vec.scale(normal, clearance - distance);
            const inward_speed = nz.vec.dot(entity.replicated_velocity, normal);
            if (inward_speed < 0) entity.replicated_velocity -= nz.vec.scale(normal, inward_speed);
        }
        const radial = nz.vec.scale(normal, nz.vec.dot(entity.replicated_velocity, normal));
        const tangential = entity.replicated_velocity - radial;
        entity.replicated_velocity = radial + nz.vec.scale(tangential, @exp(-ground_friction * world.delta_time));
        c.b3Body_SetTransform(body_id, toB3(entity.transform.position), c.b3Body_GetRotation(body_id));
        c.b3Body_SetLinearVelocity(body_id, toB3(entity.replicated_velocity));
    }

    for (world.entities.values()) |*entity| {
        const projectile_kind = entity.kind.projectileKind() orelse continue;
        const previous_position = entity.transform.position;
        entity.transform.rotation = shared.entity.projectileRotation(projectile_kind, entity.replicated_velocity, shared.Planet.up(entity.transform.position) orelse .{ 0, 1, 0 });
        entity.transform.position += nz.vec.scale(entity.replicated_velocity, world.delta_time);
        const travel = entity.transform.position - previous_position;

        entity.lifetime -= world.delta_time;
        if (entity.lifetime <= 0) {
            world.queueDespawn(entity.id);
            continue;
        }

        const ray_hit = Ray.cast(self, previous_position, travel) orelse {
            if (world.planet.sample(entity.transform.position) < 0) {
                world.impacts.appendAssumeCapacity(.{
                    .projectile = entity.id,
                    .what = .terrain,
                    .point = entity.transform.position,
                });
            }
            continue;
        };
        if (ray_hit.id == entity.owner_id) continue;
        world.impacts.appendAssumeCapacity(.{
            .projectile = entity.id,
            .what = .{ .entity = ray_hit.id },
            .point = ray_hit.point,
        });
    }
}

fn sdfGradient(position: nz.Vec3(f32), planet: *const shared.Planet) nz.Vec3(f32) {
    const epsilon: f32 = 0.05;
    return .{
        (planet.sample(position + nz.Vec3(f32){ epsilon, 0, 0 }) - planet.sample(position - nz.Vec3(f32){ epsilon, 0, 0 })) / (2 * epsilon),
        (planet.sample(position + nz.Vec3(f32){ 0, epsilon, 0 }) - planet.sample(position - nz.Vec3(f32){ 0, epsilon, 0 })) / (2 * epsilon),
        (planet.sample(position + nz.Vec3(f32){ 0, 0, epsilon }) - planet.sample(position - nz.Vec3(f32){ 0, 0, epsilon })) / (2 * epsilon),
    };
}

fn colliderGroundExtent(shape: shared.entity.ColliderShape) f32 {
    return switch (shape) {
        .box => |box| box.x,
        .capsule => |capsule| capsule.half_height + capsule.radius,
    };
}

fn isGrounded(self: *Physics, entity: *const system.Entity, planet: *const shared.Planet) bool {
    const kind_collider = entity.kind.collider() orelse return false;
    const value = planet.sample(entity.transform.position);
    const gradient_length = nz.vec.length(sdfGradient(entity.transform.position, planet));
    const distance = if (gradient_length > 0.0001) value / gradient_length else value;
    if (distance < colliderGroundExtent(kind_collider.shape) + ground_check_skin) return true;
    const position = entity.transform.position;
    const direction = -nz.vec.normalize(position);
    const ray_hit = Physics.c.b3World_CastRayClosest(
        self.world,
        .{ .x = position[0], .y = position[1], .z = position[2] },
        .{ .x = direction[0], .y = direction[1], .z = direction[2] },
        Physics.c.b3DefaultQueryFilter(),
    );
    return (ray_hit.hit);
}

pub fn createBody(self: *Physics, entity: *system.Entity) !void {
    const kind_collider = entity.kind.collider().?;
    const transform = entity.transform;

    var body_def = c.b3DefaultBodyDef();
    body_def.type = switch (kind_collider.motion) {
        .static => c.b3_staticBody,
        .kinematic => c.b3_kinematicBody,
        .dynamic => c.b3_dynamicBody,
    };
    body_def.position = toB3(transform.position);
    body_def.rotation = quatToB3(transform.rotation);
    body_def.motionLocks = .{
        .linearX = false,
        .linearY = false,
        .linearZ = false,
        .angularX = true,
        .angularY = true,
        .angularZ = true,
    };
    body_def.enableSleep = false;
    body_def.userData = @ptrFromInt(@intFromEnum(entity.id));
    const body_id = c.b3CreateBody(self.world, &body_def);
    if (kind_collider.motion == .dynamic) c.b3Body_SetLinearVelocity(body_id, toB3(entity.spawn_impulse));

    var shape_def = c.b3DefaultShapeDef();
    shape_def.density = 1;
    shape_def.filter = layerFilter(kind_collider.layer);

    switch (kind_collider.shape) {
        .box => |box| {
            var hull = c.b3MakeBoxHull(box.x, box.y, box.z);
            _ = c.b3CreateHullShape(body_id, &shape_def, &hull.base);
        },
        .capsule => |capsule| {
            const cap: c.b3Capsule = .{
                .center1 = .{ .x = 0, .y = -capsule.half_height, .z = 0 },
                .center2 = .{ .x = 0, .y = capsule.half_height, .z = 0 },
                .radius = capsule.radius,
            };
            _ = c.b3CreateCapsuleShape(body_id, &shape_def, &cap);
        },
    }
    entity.body_id = body_id;
}

pub fn destroyBody(self: *Physics, body_id: c.b3BodyId) void {
    _ = self;
    c.b3DestroyBody(body_id);
}

pub const Command = struct {
    id: shared.entity.Id,
    verb: Verb,

    pub const Verb = union(enum) {
        walk: struct { direction: nz.Vec3(f32), speed: f32 },
        hover: struct { direction: nz.Vec3(f32), speed: f32, height: f32 },
        face: nz.Vec3(f32),
        jump: f32,
        arc_jump: nz.Vec3(f32),
        teleport: nz.Vec3(f32),
        set_velocity: nz.Vec3(f32),
        set_rotation: nz.quat.Hamiltonian(f32),
    };
};

pub const Ray = struct {
    pub const Hit = struct {
        id: shared.entity.Id,
        point: nz.Vec3(f32),
    };

    pub fn cast(physics: *Physics, start: nz.Vec3(f32), translation: nz.Vec3(f32)) ?Hit {
        const ray = c.b3World_CastRayClosest(physics.world, toB3(start), toB3(translation), c.b3DefaultQueryFilter());
        if (!ray.hit) return null;
        const body = c.b3Shape_GetBody(ray.shapeId);
        return .{
            .id = @enumFromInt(@as(u32, @intCast(@intFromPtr(c.b3Body_GetUserData(body))))),
            .point = toVec(ray.point),
        };
    }
};

pub const Impact = struct {
    projectile: shared.entity.Id,
    what: union(enum) { entity: shared.entity.Id, terrain },
    point: nz.Vec3(f32),
};

fn setRotation(body_id: c.b3BodyId, rotation: nz.quat.Hamiltonian(f32)) void {
    c.b3Body_SetTransform(body_id, c.b3Body_GetPosition(body_id), quatToB3(rotation));
}

fn setPosition(body_id: c.b3BodyId, position: nz.Vec3(f32)) void {
    c.b3Body_SetTransform(body_id, toB3(position), c.b3Body_GetRotation(body_id));
}

fn setLinearVelocity(body_id: c.b3BodyId, velocity: nz.Vec3(f32)) void {
    c.b3Body_SetLinearVelocity(body_id, toB3(velocity));
}

fn faceOnPlanet(entity: *system.Entity, body_id: c.b3BodyId, direction: nz.Vec3(f32)) void {
    const planet_up = nz.vec.normalize(entity.transform.position);
    const forward_projected = direction - nz.vec.scale(planet_up, nz.vec.dot(direction, planet_up));
    if (nz.vec.length(forward_projected) <= 0.0001) return;
    const forward = nz.vec.normalize(forward_projected);
    const rotation = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
    setRotation(body_id, rotation);
}

fn moveOnPlanet(entity: *system.Entity, body_id: c.b3BodyId, dir: nz.Vec3(f32), speed: f32, delta_time: f32) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const planet_up = nz.vec.normalize(entity.transform.position);
    const wish: nz.Vec3(f32) = if (nz.vec.length(dir) > 0.0001)
        nz.vec.scale(nz.vec.normalize(dir), speed)
    else
        nz.Vec3(f32){ 0, 0, 0 };
    const velocity: nz.Vec3(f32) = toVec(c.b3Body_GetLinearVelocity(body_id));
    const radial: nz.Vec3(f32) = nz.vec.scale(planet_up, nz.vec.dot(velocity, planet_up));
    var tangential: nz.Vec3(f32) = velocity - radial;
    const to_wish: nz.Vec3(f32) = wish - tangential;
    const to_wish_length = nz.vec.length(to_wish);
    if (to_wish_length > 0.0001) {
        const step = @min(to_wish_length, move_accel * delta_time);
        tangential += nz.vec.scale(to_wish, step / to_wish_length);
    }
    c.b3Body_SetLinearVelocity(body_id, toB3(radial + tangential));
}

fn jump(entity: *system.Entity, body_id: c.b3BodyId, force: f32) void {
    const planet_up = nz.vec.normalize(entity.transform.position);
    const v = toVec(c.b3Body_GetLinearVelocity(body_id));
    const tangential = v - nz.vec.scale(planet_up, nz.vec.dot(v, planet_up));
    c.b3Body_SetLinearVelocity(body_id, toB3(tangential + nz.vec.scale(planet_up, force)));
    entity.mode = .falling;
}

const arc_jump_speed: f32 = 10;
fn arcJumpTo(entity: *system.Entity, body_id: c.b3BodyId, target: nz.Vec3(f32)) void {
    const to_target = target - entity.transform.position;
    const flight_time = nz.vec.length(to_target) / arc_jump_speed;
    if (flight_time < 0.0001) return;
    const planet_up = nz.vec.normalize(entity.transform.position);
    const velocity = nz.vec.scale(nz.vec.normalize(to_target), arc_jump_speed) + nz.vec.scale(planet_up, gravity_accel * flight_time / 2);
    c.b3Body_SetLinearVelocity(body_id, toB3(velocity));
    entity.mode = .falling;
}

fn floatOnPlanet(
    entity: *system.Entity,
    body_id: c.b3BodyId,
    dir: nz.Vec3(f32),
    speed: f32,
    planet: *const shared.Planet,
    hover_height: f32,
    delta_time: f32,
) void {
    const planet_up = nz.vec.normalize(entity.transform.position);
    moveOnPlanet(entity, body_id, dir, speed, delta_time);
    const ground_distance = planet.sample(toVec(c.b3Body_GetPosition(body_id)));
    const lift = 2 * gravity_accel * c.b3Body_GetMass(body_id) * ground_distance;
    if (ground_distance < hover_height) c.b3Body_ApplyForceToCenter(body_id, toB3(nz.vec.scale(planet_up, lift)), true);
    const velocity = toVec(c.b3Body_GetLinearVelocity(body_id));
    const radial = nz.vec.scale(planet_up, nz.vec.dot(velocity, planet_up));
    c.b3Body_SetLinearVelocity(body_id, toB3(velocity - nz.vec.scale(radial, 0.5)));
}
