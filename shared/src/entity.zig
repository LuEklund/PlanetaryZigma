const std = @import("std");
const nz = @import("numz");
const Item = @import("Item.zig");
const Stat = Item.Stat;
const enemies = @import("entity/enemies.zig");
const plain = @import("entity/plain.zig");

pub const Id = enum(u32) {
    none = 0,
    _,
};

pub const Kind = union(enum) {
    unknown,

    player,
    enemy: EnemyKind,
    item_pickup,

    teleporter,
    lootbox,
    platform,
    target_dummy,

    projectile_cube,
    projectile_rocket,

    pub fn eql(kind: Kind, other_kind: Kind) bool {
        return std.meta.eql(kind, other_kind);
    }

    pub fn projectileKind(kind: Kind) ?ProjectileKind {
        return switch (kind) {
            .projectile_cube => .cube,
            .projectile_rocket => .rocket,
            else => null,
        };
    }

    //TODO: BAD RETURN POINTER! Hot-Relaod with stored pointer will keep old data. PAY ATTENTION!
    pub fn spec(kind: Kind) *const Spec {
        return switch (kind) {
            .enemy => |enemy_kind| &enemy_specs[@intFromEnum(enemy_kind)],
            inline else => |_, tag| &@field(plain, @tagName(tag)),
        };
    }

    pub fn collider(kind: Kind) ?Collider {
        return kind.spec().collider;
    }

    pub fn modelSpec(kind: Kind) ?ModelSpec {
        return kind.spec().model;
    }
};

pub const EnemyKind = kind: {
    const decls = @typeInfo(enemies).@"struct".decls;
    const TagInt = u16;
    var field_names: [decls.len][]const u8 = undefined;
    var field_values: [decls.len]TagInt = undefined;
    for (decls, &field_names, &field_values, 0..) |decl, *name, *value, index| {
        name.* = decl.name;
        value.* = index;
    }
    break :kind @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

pub const ProjectileKind = enum(u16) {
    cube,
    rocket,
};

pub const Action = enum(u16) {
    primary,
    secondary,
    utility,
    equipment,

    pub fn cooldownStat(action: Action) Stat {
        return switch (action) {
            .primary => .primary_cooldown,
            .secondary => .secondary_cooldown,
            .utility => .utility_cooldown,
            .equipment => .equipment_cooldown,
        };
    }
};

pub const Skill = enum {
    shoot,
    spread_shot,
    dash,
    use_equipment,
    shoot_cube,
    melee,
    arc_jump,
    plant,
};

pub const AssignedSkill = struct {
    skill: Skill,
    range: f32 = 0,
    clip: ?[]const u8 = null,
};

pub const Loop = enum(u16) {
    idle,
    walk,
    death,
    stun,
};

pub fn animationLoop(velocity: nz.Vec3(f32), stun_time: f32, override: ?Loop) Loop {
    if (override) |forced| return forced;
    if (stun_time > 0) return .stun;
    return if (nz.vec.length(velocity) > 0.5) .walk else .idle;
}

pub fn projectileRotation(kind: ProjectileKind, direction: nz.Vec3(f32), up_hint: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    if (nz.vec.length(direction) < 0.001) return .identity;
    const base = nz.quat.Hamiltonian(f32).lookAt(direction, up_hint).normalize();
    return switch (kind) {
        .cube => base,
        .rocket => base.mul(nz.quat.Hamiltonian(f32).angleAxis(-std.math.pi / 2.0, .{ 1, 0, 0 })).normalize(),
    };
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

pub const ModelLookNodeNames = struct {
    spine: ?[]const u8,
    neck: ?[]const u8,
    head: ?[]const u8,
};

pub const ModelSpec = struct {
    path: []const u8,
    offset: nz.Transform3D(f32) = .{},
    loop_clips: ?std.EnumArray(Loop, ?[]const u8),
    look_node_names: ?ModelLookNodeNames = null,
    overlay_root_name: ?[]const u8 = null,
};

pub const Spec = struct {
    collider: ?Collider,
    model: ?ModelSpec,
    base_stats: std.EnumArray(Stat, f32) = .initFill(0),
    spawn_duration: f32 = 0,
    death_duration: f32 = 0,
    currency: u32 = 0,
    skills: std.EnumArray(Action, ?AssignedSkill) = .initFill(null),
};

pub const no_clip: ?[]const u8 = null;
pub const no_skill: ?AssignedSkill = null;
pub const face_camera = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 });
pub const enemy_model_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.8, 0 }, .rotation = face_camera };

const enemy_specs: [enemy_kind_count]Spec = blk: {
    var table: [enemy_kind_count]Spec = undefined;
    for (@typeInfo(enemies).@"struct".decls, &table) |decl, *slot| slot.* = @field(enemies, decl.name);
    break :blk table;
};

const enemy_kind_count: usize = @typeInfo(enemies).@"struct".decls.len;
const plain_kind_count: usize = @typeInfo(plain).@"struct".decls.len;
const all_kind_count: usize = plain_kind_count + enemy_kind_count;

pub const all_kinds: []const Kind = &all_kinds_array;
const all_kinds_array: [all_kind_count]Kind = blk: {
    var kinds: [all_kind_count]Kind = undefined;
    var kind_index: usize = 0;
    for (@typeInfo(Kind).@"union".fields) |field| {
        if (field.type == EnemyKind) continue;
        kinds[kind_index] = @unionInit(Kind, field.name, {});
        kind_index += 1;
    }
    for (std.enums.values(EnemyKind)) |enemy_kind| {
        kinds[kind_index] = .{ .enemy = enemy_kind };
        kind_index += 1;
    }
    break :blk kinds;
};
