const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Info = system.Info;
const tracy = @import("ztracy");
const nz = shared.numz;

pub const zphy = @import("zphy");

pub const body_mass: f32 = 1;
pub const gravity_accel: f32 = 50;

gpa: std.mem.Allocator,
io: std.Io,
global_state_reload: zphy.GlobalState,
physics_system: *zphy.PhysicsSystem,
broad_phase_layer_interface: *BroadPhaseLayerInterface,
object_layer_pair_filter: *ObjectLayerPairFilter,
object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
contact_listener: *ContactListener,

pub const Collider = struct {
    const Primitive = union(enum) {
        box: struct {
            size: f32,
        },
        capsule: struct {
            size: f32,
        },
        sphere: struct {
            size: f32,
        },
    };

    const Mesh = struct {
        // render_handle: usize,
        indices: []u32,
        vertices: [][4]f32,
    };
    shape: union(enum) { primitive: Primitive, mesh: Mesh },
    body_id: ?zphy.BodyId = null,
    motion_type: zphy.MotionType,
    object_layer: object_layers,
    // max_angular_velocity: f32 = 1,
};

const object_layers = enum(zphy.ObjectLayer) {
    non_moving,
    moving,
    planet_only,

    const len: u32 = @typeInfo(object_layers).@"enum".fields.len;
};

const broad_phase_layers = struct {
    const non_moving: zphy.BroadPhaseLayer = 0;
    const moving: zphy.BroadPhaseLayer = 1;
    const len: u32 = 2;
};

const BroadPhaseLayerInterface = extern struct {
    broad_phase_layer_interface: zphy.BroadPhaseLayerInterface = .init(@This()),
    object_to_broad_phase: [object_layers.len]zphy.BroadPhaseLayer = undefined,

    fn init() BroadPhaseLayerInterface {
        var object_to_broad_phase: [object_layers.len]zphy.BroadPhaseLayer = undefined;
        object_to_broad_phase[@intFromEnum(object_layers.non_moving)] = broad_phase_layers.non_moving;
        object_to_broad_phase[@intFromEnum(object_layers.moving)] = broad_phase_layers.moving;
        object_to_broad_phase[@intFromEnum(object_layers.planet_only)] = broad_phase_layers.moving;
        return .{ .object_to_broad_phase = object_to_broad_phase };
    }

    fn selfPtr(broad_phase_layer_interface: *zphy.BroadPhaseLayerInterface) *BroadPhaseLayerInterface {
        return @alignCast(@fieldParentPtr("broad_phase_layer_interface", broad_phase_layer_interface));
    }

    fn selfPtrConst(broad_phase_layer_interface: *const zphy.BroadPhaseLayerInterface) *const BroadPhaseLayerInterface {
        return @alignCast(@fieldParentPtr("broad_phase_layer_interface", broad_phase_layer_interface));
    }

    pub fn getNumBroadPhaseLayers(_: *const zphy.BroadPhaseLayerInterface) callconv(.c) u32 {
        return broad_phase_layers.len;
    }

    pub fn getBroadPhaseLayer(
        broad_phase_layer_interface: *const zphy.BroadPhaseLayerInterface,
        layer: zphy.ObjectLayer,
    ) callconv(.c) zphy.BroadPhaseLayer {
        return selfPtrConst(broad_phase_layer_interface).object_to_broad_phase[layer];
    }
};
const ObjectVsBroadPhaseLayerFilter = extern struct {
    object_vs_broad_phase_layer_filter: zphy.ObjectVsBroadPhaseLayerFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphy.ObjectVsBroadPhaseLayerFilter,
        layer1: zphy.ObjectLayer,
        layer2: zphy.BroadPhaseLayer,
    ) callconv(.c) bool {
        return switch (@as(object_layers, @enumFromInt(layer1))) {
            .non_moving => layer2 == broad_phase_layers.moving,
            .moving => true,
            .planet_only => layer2 == broad_phase_layers.non_moving,
        };
    }
};
const ObjectLayerPairFilter = extern struct {
    object_layer_pair_filter: zphy.ObjectLayerPairFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphy.ObjectLayerPairFilter,
        object1: zphy.ObjectLayer,
        object2: zphy.ObjectLayer,
    ) callconv(.c) bool {
        const other: object_layers = @enumFromInt(object2);
        return switch (@as(object_layers, @enumFromInt(object1))) {
            .non_moving => other != .non_moving,
            .moving => other != .planet_only,
            .planet_only => other == .non_moving,
        };
    }
};

const ContactListener = extern struct {
    contact_listener: zphy.ContactListener = .init(@This()),

    fn selfPtr(contact_listener: *zphy.ContactListener) *ContactListener {
        return @alignCast(@fieldParentPtr("contact_listener", contact_listener));
    }

    fn selfPtrConst(contact_listener: *const zphy.ContactListener) *const ContactListener {
        return @alignCast(@fieldParentPtr("contact_listener", contact_listener));
    }

    pub fn onContactValidate(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        base_offset: *const [3]zphy.Real,
        collision_result: *const zphy.CollideShapeResult,
    ) callconv(.c) zphy.ValidateResult {
        _ = contact_listener;
        _ = body1;
        _ = body2;
        _ = base_offset;
        _ = collision_result;
        return .accept_all_contacts;
    }

    pub fn onContactAdded(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        _: *const zphy.ContactManifold,
        _: *zphy.ContactSettings,
    ) callconv(.c) void {
        _ = contact_listener;
        _ = body1;
        _ = body2;
    }

    pub fn onContactPersisted(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        _: *const zphy.ContactManifold,
        _: *zphy.ContactSettings,
    ) callconv(.c) void {
        _ = contact_listener;
        _ = body1;
        _ = body2;
    }

    pub fn onContactRemoved(
        contact_listener: *zphy.ContactListener,
        sub_shape_id_pair: *const zphy.SubShapeIdPair,
    ) callconv(.c) void {
        _ = contact_listener;
        _ = sub_shape_id_pair;
    }
};

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io) !void {
    try zphy.init(gpa, io, .{});
    const broad_phase_layer_interface = try gpa.create(BroadPhaseLayerInterface);
    broad_phase_layer_interface.* = BroadPhaseLayerInterface.init();
    const object_layer_pair_filter = try gpa.create(ObjectLayerPairFilter);
    object_layer_pair_filter.* = .{};
    const object_vs_broad_phase_layer_filter = try gpa.create(ObjectVsBroadPhaseLayerFilter);
    object_vs_broad_phase_layer_filter.* = .{};
    const contact_listener = try gpa.create(ContactListener);
    contact_listener.* = .{};

    // Create physics system
    const physics_system = try zphy.PhysicsSystem.create(
        @as(*const zphy.BroadPhaseLayerInterface, @ptrCast(@alignCast(broad_phase_layer_interface))),
        @as(*const zphy.ObjectVsBroadPhaseLayerFilter, @ptrCast(@alignCast(object_vs_broad_phase_layer_filter))),
        @as(*const zphy.ObjectLayerPairFilter, @ptrCast(@alignCast(object_layer_pair_filter))),
        .{
            .max_bodies = 4096,
            .num_body_mutexes = 0,
            .max_body_pairs = 16384,
            .max_contact_constraints = 8192,
        },
    );

    physics_system.setGravity(.{ 0, 0, 0 });

    physics_system.optimizeBroadPhase();

    self.* = .{
        .global_state_reload = undefined,
        .gpa = gpa,
        .io = io,
        .contact_listener = contact_listener,
        .physics_system = physics_system,
        .broad_phase_layer_interface = broad_phase_layer_interface,
        .object_layer_pair_filter = object_layer_pair_filter,
        .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
    };
}

//NOTE: Jolt leaks memory ;_;
pub fn deinit(self: *@This()) void {
    std.log.err(
        \\
        \\╔════════════════════════════════════╗
        \\║ Jolt leaks 4 memory addresses!     ║
        \\╚════════════════════════════════════╝
    , .{});
    self.gpa.destroy(self.contact_listener);
    self.gpa.destroy(self.broad_phase_layer_interface);
    self.gpa.destroy(self.object_layer_pair_filter);
    self.gpa.destroy(self.object_vs_broad_phase_layer_filter);
    zphy.PhysicsSystem.destroy(self.physics_system);
    zphy.deinit();
}

pub fn reload(self: *@This(), pre_reload: bool, world: *system.World) !void {
    if (pre_reload) {
        // Serialize body states before destroying
        // TODO: Implement body serialization when you have active bodies
        std.log.debug("before", .{});

        // Destroy physics system to stop worker threads before unload
        zphy.PhysicsSystem.destroy(self.physics_system);

        std.log.debug("After", .{});
        self.physics_system = undefined;
        self.global_state_reload = zphy.preReload();
    } else {
        zphy.postReload(self.gpa, self.io, self.global_state_reload);

        // Refresh vtable pointers FIRST - before creating physics system
        self.broad_phase_layer_interface.broad_phase_layer_interface = zphy.BroadPhaseLayerInterface.init(BroadPhaseLayerInterface);
        self.object_vs_broad_phase_layer_filter.object_vs_broad_phase_layer_filter = zphy.ObjectVsBroadPhaseLayerFilter.init(ObjectVsBroadPhaseLayerFilter);
        self.object_layer_pair_filter.object_layer_pair_filter = zphy.ObjectLayerPairFilter.init(ObjectLayerPairFilter);
        self.contact_listener.contact_listener = zphy.ContactListener.init(ContactListener);

        // Recreate physics system with fresh vtable pointers
        self.physics_system = zphy.PhysicsSystem.create(
            @as(*const zphy.BroadPhaseLayerInterface, @ptrCast(@alignCast(self.broad_phase_layer_interface))),
            @as(*const zphy.ObjectVsBroadPhaseLayerFilter, @ptrCast(@alignCast(self.object_vs_broad_phase_layer_filter))),
            @as(*const zphy.ObjectLayerPairFilter, @ptrCast(@alignCast(self.object_layer_pair_filter))),
            .{
                .max_bodies = 4096,
                .num_body_mutexes = 0,
                .max_body_pairs = 16384,
                .max_contact_constraints = 8192,
            },
        ) catch unreachable;
        self.physics_system.setGravity(.{ 0, 0, 0 });
        for (world.entities.values()) |*entity| {
            if (!entity.flags.collider or !entity.flags.transform) continue;
            entity.collider.body_id = null;
            try self.createBody(entity);
        }
    }
}

pub fn update(self: *@This(), info: *const system.Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const body_interface = self.physics_system.getBodyInterfaceMut();

    // 1. Planet pull per dynamic body: gravity down + keep upright.
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.collider or !entity.flags.transform) continue;
        const body_id = entity.collider.body_id orelse continue;
        if (entity.collider.motion_type != .dynamic) continue;

        const distance_from_center = nz.vec.length(entity.transform.position);
        if (distance_from_center < 4) {
            const result = self.samplePlanetRandomSurfacePoint(info.world);
            if (result) |const_point| {
                var point = const_point;
                point += nz.vec.scale(nz.vec.normalize(point), 5);
                body_interface.setPosition(body_id, point, .activate);
                body_interface.setLinearVelocity(body_id, .{ 0, 0, 0 });
            }
            continue;
        }
        const planet_up = nz.vec.scale(entity.transform.position, 1.0 / distance_from_center);
        if (!self.isGrounded(entity, planet_up)) {
            body_interface.addForce(body_id, nz.vec.scale(-planet_up, body_mass * gravity_accel));
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
            body_interface.setRotation(body_id, entity.transform.rotation.toVec(), .activate);
        }
    }

    self.physics_system.update(info.delta_time, .{}) catch unreachable;

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.collider or !entity.flags.transform) continue;
        const body_id = entity.collider.body_id orelse continue;

        const pos = body_interface.getPosition(body_id);
        entity.transform.position = .{
            @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2]),
        };
        entity.transform.rotation = .fromVec(body_interface.getRotation(body_id));
    }
}

fn colliderGroundExtent(collider: Collider) f32 {
    return switch (collider.shape) {
        .primitive => |primitive| switch (primitive) {
            .box => |box| box.size,
            .sphere => 1,
            .capsule => 2,
        },
        .mesh => 0,
    };
}

const PlanetLayerFilter = extern struct {
    object_layer_filter: zphy.ObjectLayerFilter = .init(@This()),

    pub fn shouldCollide(_: *const zphy.ObjectLayerFilter, layer: zphy.ObjectLayer) callconv(.c) bool {
        return @as(object_layers, @enumFromInt(layer)) == .non_moving;
    }
};

fn isGrounded(self: *@This(), entity: *const system.Entity, planet_up: nz.Vec3(f32)) bool {
    const ground_check_skin: f32 = 0.2;
    const ground_reach = colliderGroundExtent(entity.collider) + ground_check_skin;
    const position = entity.transform.position;
    const ray_direction = nz.vec.scale(planet_up, -ground_reach);
    var filter: PlanetLayerFilter = .{};
    const cast_result = self.physics_system.getNarrowPhaseQuery().castRay(.{
        .origin = .{ position[0], position[1], position[2], 1 },
        .direction = .{ ray_direction[0], ray_direction[1], ray_direction[2], 0 },
    }, .{ .object_layer_filter = &filter.object_layer_filter });
    return cast_result.has_hit;
}

pub fn createBody(self: *@This(), entity: *system.Entity) !void {
    const collider = &entity.collider;
    const transform = entity.transform;
    const matrix = transform.toMat4x4();
    const body_interface = self.physics_system.getBodyInterfaceMut();

    const shape = switch (collider.shape) {
        .primitive => |primitive| switch (primitive) {
            .box => |box| shape: {
                const settings = try zphy.BoxShapeSettings.create(.{ box.size, box.size, box.size });
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
            .sphere => shape: {
                const settings = try zphy.SphereShapeSettings.create(1);
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
            .capsule => shape: {
                const settings = try zphy.CapsuleShapeSettings.create(1, 1);
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
        },
        .mesh => |mesh_shape| shape: {
            const settings = try zphy.MeshShapeSettings.create(
                mesh_shape.vertices.ptr,
                @intCast(mesh_shape.vertices.len),
                @sizeOf([4]f32),
                mesh_shape.indices,
            );
            zphy.MeshShapeSettings.sanitize(settings);
            defer settings.asShapeSettings().release();
            break :shape try settings.asShapeSettings().createShape();
        },
    };
    defer shape.release();

    const translation_only: zphy.AllowedDOFs = @enumFromInt(
        @intFromEnum(zphy.AllowedDOFs.translation_x) |
            @intFromEnum(zphy.AllowedDOFs.translation_y) |
            @intFromEnum(zphy.AllowedDOFs.translation_z),
    );
    const body_id = try body_interface.createAndAddBody(.{
        .position = matrix.vec4Position(),
        .rotation = transform.rotation.toVec(),
        .shape = shape,
        .motion_type = collider.motion_type,
        .object_layer = @intFromEnum(collider.object_layer),
        .user_data = entity.id,
        .angular_velocity = .{ 0.0, 0.0, 0.0, 0 },
        .allowed_DOFs = translation_only,
        .override_mass_properties = .calc_inertia,
        .mass_properties_override = .{ .mass = body_mass },
        .max_linear_velocity = 10000,
        .allow_sleeping = false,
    }, .activate);
    collider.body_id = body_id;
}

pub fn destroyBody(self: *@This(), body_id: zphy.BodyId) void {
    const body_interface = self.physics_system.getBodyInterfaceMut();
    body_interface.removeAndDestroyBody(body_id);
}

pub fn moveOnPlanet(
    body_interface: *zphy.BodyInterface,
    body_id: zphy.BodyId,
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
    const v: nz.Vec3(f32) = body_interface.getLinearVelocity(body_id);
    const radial: nz.Vec3(f32) = if (vertical != 0)
        nz.vec.scale(planet_up, vertical)
    else
        nz.vec.scale(planet_up, nz.vec.dot(v, planet_up));
    body_interface.setLinearVelocity(body_id, radial + walk);
}

pub fn samplePlanetRandomSurfacePoint(self: *@This(), world: *system.World) ?nz.Vec3(f32) {
    const random = world.prng.random();
    const direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
    const origin = nz.vec.scale(direction, @floatFromInt(world.planet_size));

    const ray_direction = nz.vec.scale(origin, -2.0);

    const ray: zphy.RRayCast = .{
        .origin = .{ origin[0], origin[1], origin[2], 1.0 },
        .direction = .{ ray_direction[0], ray_direction[1], ray_direction[2], 0.0 },
    };

    var layer_filter: PlanetLayerFilter = .{};

    const result = self.physics_system
        .getNarrowPhaseQuery()
        .castRay(ray, .{
        .object_layer_filter = &layer_filter.object_layer_filter,
    });

    if (!result.has_hit) return null;

    return ray.getPointOnRay(result.hit.fraction);
}

pub fn getSurfacePoint(self: *@This(), world: *system.World, from_point: nz.Vec3(f32)) ?nz.Vec3(f32) {
    const origin = nz.vec.scale(nz.vec.normalize(from_point), @floatFromInt(world.planet_size));

    const ray_direction = nz.vec.scale(origin, -2.0);

    const ray: zphy.RRayCast = .{
        .origin = .{ origin[0], origin[1], origin[2], 1.0 },
        .direction = .{ ray_direction[0], ray_direction[1], ray_direction[2], 0.0 },
    };

    var layer_filter: PlanetLayerFilter = .{};

    const result = self.physics_system
        .getNarrowPhaseQuery()
        .castRay(ray, .{
        .object_layer_filter = &layer_filter.object_layer_filter,
    });

    if (!result.has_hit) return null;

    return ray.getPointOnRay(result.hit.fraction);
}
