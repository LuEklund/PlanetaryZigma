const std = @import("std");
const nz = @import("numz");
const Item = @import("inventory.zig").Item;
const Stats = @import("Stats.zig");

pub const Id = enum(u32) {
    none = 0,
    _,
};

pub const EnemyKind = enum(u16) {
    tubloid = 0,
    tubloida = 1,
    bloorpLord = 2,
};

pub const ProjectileKind = enum(u16) {
    cube = 0,
    rocket = 1,
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
    capsule: struct { half_heigth: f32, radius: f32 },
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

pub const ModelClipNames = struct {
    idle: ?[]const u8,
    walk: []const u8,
    attack: []const u8,
};

pub const ModelLookNodeNames = struct {
    spine: ?[]const u8,
    neck: ?[]const u8,
    head: ?[]const u8,
};

pub const ModelSpec = struct {
    key: []const u8,
    offset: nz.Transform3D(f32) = .{},
    skinned: bool,
    clip_names: ?ModelClipNames,
    look_node_names: ?ModelLookNodeNames = null,
    overlay_root_name: ?[]const u8 = null,
};

const face_camera = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 });
const player_model_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.8, 0 }, .rotation = face_camera };
const enemy_model_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.6, 0 }, .rotation = face_camera };

pub fn modelSpec(kind: Kind) ModelSpec {
    return spec(kind).model;
}

pub const Spec = struct {
    collider: ?Collider,
    model: ModelSpec,
    icon: ?[]const u8 = null,
    has_health: bool,
    expects_model: bool,
    stats: ?Stats.Values = null,
    spawn_duration: f32 = 0,
    death_duration: f32 = 0,
    currency: u32 = 0,
};

pub fn spec(kind: Kind) Spec {
    return switch (kind) {
        .unknown => .{
            .collider = null,
            .model = .{ .key = "default", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = false,
        },
        .player => .{
            .collider = .{ .shape = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
            .model = .{
                .key = "objects/BenBozo.glb",
                .offset = player_model_offset,
                .skinned = true,
                .clip_names = .{
                    .idle = "Idle",
                    .walk = "Run",
                    .attack = "shoot",
                },
                .look_node_names = .{ .spine = "mixamorig:Spine2", .neck = "mixamorig:Neck", .head = null },
                .overlay_root_name = "mixamorig:Spine1",
            },
            .has_health = true,
            .expects_model = true,
            .stats = .initDefault(0, .{ .health = 100, .speed = 10, .damage = 1, .attack_speed = 6, .range = 10, .regen = 1 }),
            .currency = 100,
        },
        .planet => .{
            .collider = null,
            .model = .{ .key = "planet", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = false,
        },
        .teleporter => .{
            .collider = .{ .shape = .{ .box = .{ .x = 1, .y = 5, .z = 1 } }, .motion = .static, .layer = .non_moving },
            .model = .{ .key = "objects/pillar.glb", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = false,
        },
        .lootbox => .{
            .collider = .{ .shape = .{ .box = .{ .x = 1, .y = 1, .z = 1 } }, .motion = .static, .layer = .moving },
            .model = .{ .key = "objects/lootbox.glb", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = true,
            .death_duration = 0.35,
            .currency = 10,
        },
        .projectile_cube => .{
            .collider = null,
            .model = .{ .key = "cube_projectile", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = true,
        },
        .projectile_rocket => .{
            .collider = null,
            .model = .{ .key = "objects/rocket.glb", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = true,
        },
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .key = "objects/Tubloid.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack" } },
                .has_health = true,
                .expects_model = true,
                .stats = .initDefault(0, .{ .health = 20, .speed = 3, .damage = 1, .attack_speed = 1, .range = 2 }),
                .currency = 5,
            },
            .tubloida => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .key = "objects/Tubloida.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack_range" } },
                .has_health = true,
                .expects_model = true,
                .stats = .initDefault(0, .{ .health = 20, .speed = 3, .damage = 1, .attack_speed = 0.2, .range = 10 }),
                .currency = 7,
            },
            .bloorpLord => .{
                .collider = .{ .shape = .{ .capsule = .{ .half_heigth = 2, .radius = 2 } }, .motion = .dynamic, .layer = .moving },
                .model = .{ .key = "objects/BloorpLord.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{
                    .idle = "Idle",
                    .walk = "Walking",
                    .attack = "Spawn_Enemy",
                } },
                .has_health = true,
                .expects_model = true,
                .stats = .initDefault(0, .{ .health = 100, .speed = 10, .damage = 1, .attack_speed = 0.25, .range = 40 }),
                .currency = 100,
            },
        },
        .item => |item_kind| .{
            .collider = .{ .shape = .{ .box = .{ .x = 1, .y = 1, .z = 1 } }, .motion = .dynamic, .layer = .planet_only },
            .model = .{ .key = Item.spec(item_kind).model, .skinned = false, .clip_names = null },
            .icon = Item.spec(item_kind).icon,
            .has_health = false,
            .expects_model = true,
            .spawn_duration = 0.35,
        },
    };
}

pub const all_kinds: []const Kind = blk: {
    var kinds: []const Kind = &.{ .unknown, .player, .planet, .teleporter, .lootbox, .projectile_cube, .projectile_rocket };
    for (std.enums.values(EnemyKind)) |enemy_kind| kinds = kinds ++ .{Kind{ .enemy = enemy_kind }};
    for (std.enums.values(Item)) |item_kind| kinds = kinds ++ .{Kind{ .item = item_kind }};
    break :blk kinds;
};

pub const Kind = union(enum) {
    unknown,

    player,
    enemy: EnemyKind,
    item: Item,

    planet,
    teleporter,
    lootbox,

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

    pub fn expectsModel(kind: Kind) bool {
        return spec(kind).expects_model;
    }
};

pub const State = enum(u16) {
    idle = 0,
    walk = 1,
    attack = 2,
};
