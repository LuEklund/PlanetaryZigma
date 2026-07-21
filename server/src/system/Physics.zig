const Physics = @This();

const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

pub const c = @import("box3d");

pub const gravity_accel: f32 = 50;

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

pub const Collider = struct {
    pub const Mesh = struct {
        indices: []u32,
        vertices: [][4]f32,
    };
    shape: union(enum) { primitive: shared.entity.ColliderShape, mesh: Mesh },
    body_id: ?c.b3BodyId = null,
    motion_type: MotionType,
    object_layer: ObjectLayer,
};

pub fn toVec(v: c.b3Vec3) nz.Vec3(f32) {
    return .{ v.x, v.y, v.z };
}

pub fn toB3(v: nz.Vec3(f32)) c.b3Vec3 {
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
        for (world.entities.values()) |*entity| {
            if (!shared.entity.hasCollider(entity.kind)) continue;
            if (shared.entity.collider(entity.kind)) |kind_collider| {
                entity.collider.shape = .{ .primitive = kind_collider.shape };
                entity.collider.motion_type = kind_collider.motion;
                entity.collider.object_layer = kind_collider.layer;
            }
            entity.collider.body_id = null;
            try self.createBody(entity);
        }
        for (world.planet_chunks.items) |*chunk| {
            chunk.body_id = if (chunk.mesh.indices.len == 0) null else try self.createStaticMeshBody(chunk.mesh);
        }
    }
}

pub fn update(self: *Physics, info: *const system.Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (info.world.entities.values()) |*entity| {
        if (!shared.entity.hasCollider(entity.kind)) continue;
        const body_id = entity.collider.body_id orelse continue;
        if (entity.collider.motion_type != .dynamic) continue;

        const distance_from_center = nz.vec.length(entity.transform.position);
        if (distance_from_center < 4) {
            const direction = nz.vec.randomUnitVector(nz.Vec3(f32), info.world.prng.random());
            var point = shared.planet.surfacePoint(direction, info.world.planet_radius);
            point += nz.vec.scale(nz.vec.normalize(point), 5);
            c.b3Body_SetTransform(body_id, toB3(point), c.b3Body_GetRotation(body_id));
            c.b3Body_SetLinearVelocity(body_id, .{ .x = 0, .y = 0, .z = 0 });
            continue;
        }
        const planet_up = nz.vec.scale(entity.transform.position, 1.0 / distance_from_center);
        if (!self.isGrounded(entity, planet_up)) {
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

    c.b3World_Step(self.world, info.delta_time, 4);

    for (info.world.entities.values()) |*entity| {
        if (!shared.entity.hasCollider(entity.kind)) continue;
        const body_id = entity.collider.body_id orelse continue;

        const pos = c.b3Body_GetPosition(body_id);
        entity.transform.position = .{ pos.x, pos.y, pos.z };
        entity.transform.rotation = quatFromB3(c.b3Body_GetRotation(body_id));
        entity.replicated_velocity = toVec(c.b3Body_GetLinearVelocity(body_id));
    }
}

fn colliderGroundExtent(collider: Collider) f32 {
    return switch (collider.shape) {
        .primitive => |primitive| switch (primitive) {
            .box => |box| box.x,
            .capsule => |capsule| capsule.half_heigth + capsule.radius,
        },
        .mesh => 0,
    };
}

fn planetRayFilter() c.b3QueryFilter {
    var filter = c.b3DefaultQueryFilter();
    filter.maskBits = Category.non_moving;
    return filter;
}

fn isGrounded(self: *Physics, entity: *const system.Entity, planet_up: nz.Vec3(f32)) bool {
    const ground_check_skin: f32 = 0.2;
    const ground_reach = colliderGroundExtent(entity.collider) + ground_check_skin;
    const translation = nz.vec.scale(planet_up, -ground_reach);
    const result = c.b3World_CastRayClosest(self.world, toB3(entity.transform.position), toB3(translation), planetRayFilter());
    return result.hit;
}

pub fn createBody(self: *Physics, entity: *system.Entity) !void {
    const collider = &entity.collider;
    const transform = entity.transform;

    var body_def = c.b3DefaultBodyDef();
    body_def.type = switch (collider.motion_type) {
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
    if (collider.motion_type == .dynamic) c.b3Body_SetLinearVelocity(body_id, toB3(entity.spawn_impulse));

    var shape_def = c.b3DefaultShapeDef();
    shape_def.density = 1;
    shape_def.filter = layerFilter(collider.object_layer);

    switch (collider.shape) {
        .primitive => |primitive| switch (primitive) {
            .box => |box| {
                var hull = c.b3MakeBoxHull(box.x, box.y, box.z);
                _ = c.b3CreateHullShape(body_id, &shape_def, &hull.base);
            },
            .capsule => |capsule| {
                const cap: c.b3Capsule = .{
                    .center1 = .{ .x = 0, .y = -capsule.half_heigth, .z = 0 },
                    .center2 = .{ .x = 0, .y = capsule.half_heigth, .z = 0 },
                    .radius = capsule.radius,
                };
                _ = c.b3CreateCapsuleShape(body_id, &shape_def, &cap);
            },
        },
        .mesh => |mesh_shape| {
            const vertices = try self.gpa.alloc(c.b3Vec3, mesh_shape.vertices.len);
            defer self.gpa.free(vertices);
            for (vertices, mesh_shape.vertices) |*out, in| out.* = .{ .x = in[0], .y = in[1], .z = in[2] };
            const indices = try self.gpa.alloc(i32, mesh_shape.indices.len);
            defer self.gpa.free(indices);
            for (indices, mesh_shape.indices) |*out, in| out.* = @intCast(in);

            var mesh_def = std.mem.zeroes(c.b3MeshDef);
            mesh_def.vertices = vertices.ptr;
            mesh_def.indices = indices.ptr;
            mesh_def.vertexCount = @intCast(vertices.len);
            mesh_def.triangleCount = @intCast(@divExact(indices.len, 3));
            const mesh_data = c.b3CreateMesh(&mesh_def, null, 0);
            _ = c.b3CreateMeshShape(body_id, &shape_def, mesh_data, .{ .x = 1, .y = 1, .z = 1 });
        },
    }
    collider.body_id = body_id;
}

pub fn createStaticMeshBody(self: *Physics, mesh: Collider.Mesh) !c.b3BodyId {
    var body_def = c.b3DefaultBodyDef();
    body_def.type = c.b3_staticBody;
    const body_id = c.b3CreateBody(self.world, &body_def);
    errdefer c.b3DestroyBody(body_id);

    var shape_def = c.b3DefaultShapeDef();
    shape_def.filter = layerFilter(.non_moving);

    const vertices = try self.gpa.alloc(c.b3Vec3, mesh.vertices.len);
    defer self.gpa.free(vertices);
    for (vertices, mesh.vertices) |*out, in| out.* = .{ .x = in[0], .y = in[1], .z = in[2] };
    const indices = try self.gpa.alloc(i32, mesh.indices.len);
    defer self.gpa.free(indices);
    for (indices, mesh.indices) |*out, in| out.* = @intCast(in);

    var mesh_def = std.mem.zeroes(c.b3MeshDef);
    mesh_def.vertices = vertices.ptr;
    mesh_def.indices = indices.ptr;
    mesh_def.vertexCount = @intCast(vertices.len);
    mesh_def.triangleCount = @intCast(@divExact(indices.len, 3));
    const mesh_data = c.b3CreateMesh(&mesh_def, null, 0);
    _ = c.b3CreateMeshShape(body_id, &shape_def, mesh_data, .{ .x = 1, .y = 1, .z = 1 });
    return body_id;
}

pub fn destroyBody(self: *Physics, body_id: c.b3BodyId) void {
    _ = self;
    c.b3DestroyBody(body_id);
}

pub fn setRotation(body_id: c.b3BodyId, rotation: nz.quat.Hamiltonian(f32)) void {
    c.b3Body_SetTransform(body_id, c.b3Body_GetPosition(body_id), quatToB3(rotation));
}

pub fn setPosition(body_id: c.b3BodyId, position: nz.Vec3(f32)) void {
    c.b3Body_SetTransform(body_id, toB3(position), c.b3Body_GetRotation(body_id));
}

pub fn setLinearVelocity(body_id: c.b3BodyId, velocity: nz.Vec3(f32)) void {
    c.b3Body_SetLinearVelocity(body_id, toB3(velocity));
}

pub fn moveOnPlanet(
    body_id: c.b3BodyId,
    planet_up: nz.Vec3(f32),
    dir: nz.Vec3(f32),
    speed: f32,
    vertical: f32,
) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const walk: nz.Vec3(f32) = if (nz.vec.length(dir) > 0.0001)
        nz.vec.scale(nz.vec.normalize(dir), speed)
    else
        nz.Vec3(f32){ 0, 0, 0 };
    const v: nz.Vec3(f32) = toVec(c.b3Body_GetLinearVelocity(body_id));
    const radial: nz.Vec3(f32) = if (vertical != 0)
        nz.vec.scale(planet_up, vertical)
    else
        nz.vec.scale(planet_up, nz.vec.dot(v, planet_up));
    c.b3Body_SetLinearVelocity(body_id, toB3(radial + walk));
}

pub fn moveTowardsOnPlanet(
    body_id: c.b3BodyId,
    planet_up: nz.Vec3(f32),
    dir: nz.Vec3(f32),
    target_speed: f32,
    accel: f32,
    delta_time: f32,
) void {
    const velocity = toVec(c.b3Body_GetLinearVelocity(body_id));
    const radial = nz.vec.scale(planet_up, nz.vec.dot(velocity, planet_up));
    const tangential = velocity - radial;

    const target: nz.Vec3(f32) = if (nz.vec.length(dir) > 0.0001)
        nz.vec.scale(nz.vec.normalize(dir), target_speed)
    else
        .{ 0, 0, 0 };

    const to_target = target - tangential;
    const distance_to_target = nz.vec.length(to_target);
    const step = accel * delta_time;
    const new_tangential = if (distance_to_target <= step)
        target
    else
        tangential + nz.vec.scale(to_target, step / distance_to_target);

    c.b3Body_SetLinearVelocity(body_id, toB3(radial + new_tangential));
}
