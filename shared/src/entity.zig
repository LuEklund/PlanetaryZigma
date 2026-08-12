const std = @import("std");
const nz = @import("numz");
const Item = @import("Item.zig");
const Stat = Item.Stat;

pub const Id = enum(u32) {
    none = 0,
    _,
};

pub const EnemyKind = enum(u16) {
    tubloid,
    tubloida,
    bloorp_lord,
    hunkloid,
    blooploid,

    acorn,
    grass1,
    healer,
    pub const count: usize = @typeInfo(EnemyKind).@"enum".fields.len;
};

pub const ProjectileKind = enum(u16) {
    cube,
    rocket,
};

pub fn projectileRotation(kind: ProjectileKind, direction: nz.Vec3(f32), up_hint: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    if (nz.vec.length(direction) < 0.001) return .identity;
    const base = nz.quat.Hamiltonian(f32).lookAt(direction, up_hint).normalize();
    return switch (kind) {
        .cube => base,
        .rocket => base.mul(nz.quat.Hamiltonian(f32).angleAxis(-std.math.pi / 2.0, .{ 1, 0, 0 })).normalize(),
    };
}

pub fn hasCollider(kind: Kind) bool {
    return spec(kind).collider != null;
}

pub const ColliderShape = union(enum) {
    box: HalfBoxExtent,
    capsule: struct { half_height: f32, radius: f32 },
    pub const HalfBoxExtent = struct {
        x: f32,
        y: f32,
        z: f32,
    };
};

pub const MotionType = enum { static, kinematic, dynamic };

pub const ObjectLayer = enum { non_moving, moving, planet_only };

pub const Collider = struct {
    shape: ColliderShape,
    motion: MotionType,
    layer: ObjectLayer,
};

pub fn collider(kind: Kind) ?Collider {
    return spec(kind).collider;
}

const no_clip: ?[]const u8 = null;

pub const ModelLookNodeNames = struct {
    spine: ?[]const u8,
    neck: ?[]const u8,
    head: ?[]const u8,
};

pub const ModelSpec = struct {
    path: []const u8,
    offset: nz.Transform3D(f32) = .{},
    clip_names: ?std.EnumArray(State, ?[]const u8),
    look_node_names: ?ModelLookNodeNames = null,
    overlay_root_name: ?[]const u8 = null,
};

const face_camera = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 });
const enemy_model_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.8, 0 }, .rotation = face_camera };

pub fn modelSpec(kind: Kind) ?ModelSpec {
    return spec(kind).model;
}

pub const Spec = struct {
    collider: ?Collider,
    model: ?ModelSpec,
    has_health: bool,
    base_stats: ?std.EnumArray(Stat, f32) = null,
    spawn_duration: f32 = 0,
    death_duration: f32 = 0,
    currency: u32 = 0,
    range: std.EnumArray(Slot, f32) = .initFill(0),
};

pub fn spec(kind: Kind) Spec {
    return switch (kind) {
        .unknown => .{
            .collider = null,
            .model = null,
            .has_health = false,
        },
        .player => .{
            .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.3 } }, .motion = .dynamic, .layer = .moving },
            .model = .{
                .path = "objects/BenBozo.glb",
                .offset = .{ .position = .{ 0, -0.5, 0 }, .rotation = face_camera },
                .clip_names = .initDefault(no_clip, .{
                    .idle = "Idle",
                    .walk = "Run",
                    .attack = "Run",
                    .death = "Death",
                }),
                .look_node_names = .{ .spine = "mixamorig:Spine2", .neck = "mixamorig:Neck", .head = null },
                .overlay_root_name = "mixamorig:Spine1",
            },
            .has_health = true,
            .base_stats = .initDefault(0, .{
                .health = 100,
                .speed = 10,
                .damage = 1,
                .regen = 1,
                .primary_cooldown = 0.3,
                .utility_cooldown = 5,
                .secondary_cooldown = 5,
                .equipment_cooldown = 5,
            }),
            .range = .initDefault(0, .{ .primary = 10 }),
            .currency = 100,
        },
        .teleporter => .{
            .collider = .{ .shape = .{ .box = .{ .x = 1, .y = 5, .z = 1 } }, .motion = .static, .layer = .non_moving },
            .model = .{ .path = "objects/pillar.glb", .clip_names = null },
            .has_health = false,
        },
        .lootbox => .{
            .collider = .{ .shape = .{ .box = .{ .x = 0.6, .y = 0.6, .z = 0.6 } }, .motion = .static, .layer = .moving },
            .model = .{ .path = "objects/lootbox.glb", .clip_names = null },
            .has_health = false,
            .death_duration = 0.35,
            .currency = 10,
        },
        .platform => .{
            .collider = .{ .shape = .{ .box = .{ .x = 20, .y = 0.5, .z = 20 } }, .motion = .static, .layer = .non_moving },
            .model = null,
            .has_health = false,
        },
        .target_dummy => .{
            .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .static, .layer = .non_moving },
            .model = .{ .path = "objects/Tubloid.glb", .offset = enemy_model_offset, .clip_names = .initDefault(no_clip, .{
                .idle = "idle",
                .walk = "walk",
                .attack = "attack",
                .death = "Death",
            }) },
            .has_health = true,
            .base_stats = .initDefault(0, .{ .health = 1000 }),
        },
        .projectile_cube => .{
            .collider = null,
            .model = null,
            .has_health = true,
            .base_stats = .initDefault(0, .{ .health = 1 }),
        },
        .projectile_rocket => .{
            .collider = null,
            .model = .{ .path = "objects/rocket.glb", .clip_names = null },
            .has_health = true,
            .base_stats = .initDefault(0, .{ .health = 1 }),
        },
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/Tubloid.glb", .offset = enemy_model_offset, .clip_names = .initDefault(no_clip, .{
                    .idle = "idle",
                    .walk = "walk",
                    .attack = "attack",
                    .death = "Death",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 25, .speed = 3, .damage = 10, .primary_cooldown = 1 }),
                .range = .initDefault(0, .{ .primary = 2 }),
                .currency = 5,
            },
            .tubloida => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/Tubloida.glb", .offset = enemy_model_offset, .clip_names = .initDefault(no_clip, .{
                    .idle = "idle",
                    .walk = "walk",
                    .attack = "attack_range",
                    .death = "Death",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 10, .speed = 3, .damage = 5, .primary_cooldown = 5 }),
                .range = .initDefault(0, .{ .primary = 10 }),
                .currency = 7,
            },
            .hunkloid => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.6, .radius = 1 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/Hunkloid.glb", .offset = .{ .position = .{ 0, -1.8, 0 }, .rotation = face_camera }, .clip_names = .initDefault(no_clip, .{
                    .idle = "Idle",
                    .walk = "Walk",
                    .attack = "Attack",
                    .death = "Death",
                    .utility = "Secondary",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 50, .speed = 1, .damage = 25, .primary_cooldown = 5, .utility_cooldown = 5 }),
                .range = .initDefault(0, .{ .primary = 3, .utility = 12 }),
                .currency = 30,
            },
            .bloorp_lord => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 1.5, .radius = 4.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/BloorpLord.glb", .offset = .{ .position = .{ 0, -10, 0 }, .rotation = face_camera }, .clip_names = .initDefault(no_clip, .{
                    .idle = "Idle",
                    .walk = "Walking",
                    .attack = "Spawn_Enemy",
                    .death = "Death",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 100, .speed = 30, .damage = 10, .primary_cooldown = 0.01 }),
                .range = .initDefault(0, .{ .primary = 40 }),
                .currency = 100,
            },
            .blooploid => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/Blooploid.glb", .offset = enemy_model_offset, .clip_names = null },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 10, .speed = 10, .damage = 5, .primary_cooldown = 5 }),
                .range = .initDefault(0, .{ .primary = 15 }),
                .currency = 7,
            },
            .acorn => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.05, .radius = 0.4 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/acorn.glb", .offset = .{ .position = .{ 0, -0.4, 0 }, .rotation = face_camera }, .clip_names = .initDefault(no_clip, .{
                    .idle = "Idle",
                    .walk = "Run",
                    .utility = "Planted",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 5, .speed = 10, .damage = 1, .primary_cooldown = 2 }),
                .range = .initDefault(0, .{ .primary = 2 }),
                .currency = 5,
            },
            .grass1 => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.45, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/grass1.glb", .offset = .{ .position = .{ 0, -1, 0 }, .rotation = face_camera }, .clip_names = .initDefault(no_clip, .{
                    .idle = "Idle",
                    .walk = "Walk",
                    .attack = "Attack",
                }) },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 30, .speed = 3, .damage = 10, .primary_cooldown = 0.75 }),
                .range = .initDefault(0, .{ .primary = 2 }),
                .currency = 25,
            },
            .healer => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .path = "objects/Healer.glb", .offset = enemy_model_offset, .clip_names = null },
                .has_health = true,
                .base_stats = .initDefault(0, .{ .health = 10, .speed = 10, .damage = -1, .primary_cooldown = 0.2 }),
                .range = .initDefault(0, .{ .primary = 15 }),
                .currency = 7,
            },
        },
        .item => |item_kind| .{
            .collider = .{ .shape = .{ .box = .{ .x = 1, .y = 1, .z = 1 } }, .motion = .dynamic, .layer = .planet_only },
            .model = .{ .path = Item.getModel(item_kind), .clip_names = null },
            .has_health = false,
            .spawn_duration = 0.35,
        },
    };
}

pub const all_kinds: []const Kind = &all_kinds_array;

const all_kind_count: usize = 8 + EnemyKind.count + Item.items.len;
const all_kinds_array: [all_kind_count]Kind = blk: {
    var kinds: [all_kind_count]Kind = undefined;
    kinds[0..8].* = .{ .unknown, .player, .teleporter, .lootbox, .platform, .target_dummy, .projectile_cube, .projectile_rocket };
    var kind_index: usize = 8;
    for (std.enums.values(EnemyKind)) |enemy_kind| {
        kinds[kind_index] = .{ .enemy = enemy_kind };
        kind_index += 1;
    }
    for (std.enums.values(Item.Kind)) |item_kind| {
        kinds[kind_index] = .{ .item = item_kind };
        kind_index += 1;
    }
    break :blk kinds;
};

pub const Kind = union(enum) {
    unknown,

    player,
    enemy: EnemyKind,
    item: Item.Kind,

    teleporter,
    lootbox,
    platform,
    target_dummy,

    projectile_cube,
    projectile_rocket,

    pub fn eql(kind: Kind, other_kind: Kind) bool {
        return std.meta.eql(kind, other_kind);
    }

    pub fn hasHealth(kind: Kind) bool {
        return spec(kind).has_health;
    }

    pub fn projectileKind(kind: Kind) ?ProjectileKind {
        return switch (kind) {
            .projectile_cube => .cube,
            .projectile_rocket => .rocket,
            else => null,
        };
    }
};

pub const Slot = enum {
    primary,
    secondary,
    utility,
    equipment,

    pub fn state(slot: Slot) State {
        return switch (slot) {
            .primary => .attack,
            .secondary => .secondary,
            .utility => .utility,
            .equipment => .equipment,
        };
    }
};

pub fn animationState(velocity: nz.Vec3(f32), stun_time: f32, override: ?State) State {
    if (override) |forced| return forced;
    if (stun_time > 0) return .stun;
    return if (nz.vec.length(velocity) > 0.5) .walk else .idle;
}

pub const State = enum(u16) {
    idle,
    walk,
    attack,
    death,
    utility,
    secondary,
    equipment,
    stun,

    pub fn slot(state: State) ?Slot {
        return switch (state) {
            .attack => .primary,
            .secondary => .secondary,
            .utility => .utility,
            .equipment => .equipment,
            .idle, .walk, .death, .stun => null,
        };
    }
};
