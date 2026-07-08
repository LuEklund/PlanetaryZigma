const std = @import("std");
const Item = @import("inventory.zig").Item;

pub const Enemy = struct {
    pub const Kind = enum(u16) {
        tubloid,
        tubloida,
        wizard,
    };
};

pub fn hasCollider(kind: Kind) bool {
    return switch (kind) {
        .unknown, .bullet => false,
        else => true,
    };
}

pub const ColliderShape = union(enum) {
    box: struct { half_extent: f32 },
    capsule: struct { half_heigth: f32, radius: f32 },
};

pub fn colliderShape(kind: Kind) ?ColliderShape {
    return switch (kind) {
        .unknown, .bullet, .planet => null,
        .player => .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid, .tubloida => .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
            .wizard => .{ .capsule = .{ .half_heigth = 2, .radius = 2 } },
        },
        .teleporter, .item => .{ .box = .{ .half_extent = 1 } },
    };
}

pub fn hasHealth(kind: Kind) bool {
    return kind == .player or kind == .enemy;
}

pub const Kind = union(enum(u16)) {
    unknown,
    player,
    planet,
    bullet,

    teleporter,

    enemy: Enemy.Kind,
    item: Item.Kind,

    pub fn eql(kind: Kind, other_kind: Kind) bool {
        return std.meta.eql(kind, other_kind);
    }

    pub fn expectsModel(kind: Kind) bool {
        return switch (kind) {
            .player, .planet, .enemy, .item => true,
            .unknown, .bullet, .teleporter => false,
        };
    }
};

pub const State = enum(u16) {
    idle,
    walk,
    attack,
};
