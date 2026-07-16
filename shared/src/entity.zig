const std = @import("std");
const Item = @import("inventory.zig").Item;

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

pub fn hasCollider(kind: Kind) bool {
    return switch (kind) {
        .unknown, .projectile_cube, .projectile_rocket => false,
        else => true,
    };
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

pub fn colliderShape(kind: Kind) ?ColliderShape {
    return switch (kind) {
        .unknown, .projectile_cube, .projectile_rocket, .planet => null,
        .player => .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid, .tubloida => .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
            .bloorpLord => .{ .capsule = .{ .half_heigth = 2, .radius = 2 } },
        },
        .teleporter => .{ .box = .{ .x = 1, .y = 5, .z = 1 } },
        .item => .{ .box = .{ .x = 1, .y = 1, .z = 1 } },
        .lootbox => .{ .box = .{ .x = 1, .y = 1, .z = 1 } },
    };
}

pub const Kind = union(enum) {
    unknown,

    player,
    enemy: EnemyKind,
    item: Item.Kind,

    planet,
    teleporter,
    lootbox,

    projectile_cube,
    projectile_rocket,

    pub fn eql(kind: Kind, other_kind: Kind) bool {
        return std.meta.eql(kind, other_kind);
    }

    pub fn hasHealth(kind: Kind) bool {
        return kind == .enemy or kind == .player;
    }

    pub fn projectileKind(kind: Kind) ?ProjectileKind {
        return switch (kind) {
            .projectile_cube => .cube,
            .projectile_rocket => .rocket,
            else => null,
        };
    }

    pub fn expectsModel(kind: Kind) bool {
        return switch (kind) {
            .player, .planet, .enemy, .item, .projectile_cube, .projectile_rocket, .lootbox => true,
            .unknown, .teleporter => false,
        };
    }
};

pub const State = enum(u16) {
    idle = 0,
    walk = 1,
    attack = 2,
};
