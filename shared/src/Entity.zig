const Item = @import("inventory.zig").Item;

pub fn isEnemy(kind: Kind) bool {
    return switch (kind) {
        .skelly, .wizard => true,
        else => false,
    };
}

pub fn isItem(kind: Kind) bool {
    return switch (kind) {
        .health_item,
        .speed_item,
        .damage_item,
        .attack_speed_item,
        => true,
        else => false,
    };
}

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
        .skelly => .{ .capsule = .{ .half_heigth = 0.8, .radius = 0.8 } },
        .wizard => .{ .capsule = .{ .half_heigth = 2, .radius = 2 } },
        .teleporter,
        .health_item,
        .speed_item,
        .damage_item,
        .attack_speed_item,
        => .{ .box = .{ .half_extent = 1 } },
    };
}

pub fn hasHealth(kind: Kind) bool {
    return kind == .player or isEnemy(kind);
}

pub const Kind = enum(u16) {
    unknown,
    player,
    planet,
    bullet,

    teleporter,

    skelly,
    wizard,

    health_item,
    speed_item,
    damage_item,
    attack_speed_item,

    pub fn expectsModel(kind: Kind) bool {
        return switch (kind) {
            .player, .planet => true,
            .unknown, .bullet => false,
            else => isEnemy(kind) or isItem(kind),
        };
    }

    pub fn toItem(kind: Kind) ?Item.Kind {
        return switch (kind) {
            .health_item => .health_potion,
            .speed_item => .speed_potion,
            .damage_item => .damage_potion,
            .attack_speed_item => .attack_speed_potion,
            else => null,
        };
    }
};

pub const State = enum(u16) {
    idle,
    walk,
    attack,
};
