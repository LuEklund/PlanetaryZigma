const std = @import("std");
const nz = @import("numz");
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
    // TEMP-COMMENT: planet gets a physics body but its collider is the generated planet
    // MESH (assigned by planet setup), not a primitive — hence the special case.
    return kind == .planet or spec(kind).collider != null;
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
    return spec(kind).collider;
}

// TEMP-COMMENT: per-kind render-asset data, same pattern as colliderShape above — adding an
// entity now declares its collider AND its model in this ONE file. The server compiles the
// strings and ignores them; the client's Resources iterates all_kinds and loads everything.
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
    // TEMP-COMMENT: pool key. Keys ending in ".glb" are loaded (and hot-reload watched) from
    // assets/; any other key is a generated mesh the client registers manually (box, planet).
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

// TEMP-COMMENT: ONE row per entity kind — collider, model, flags together. Adding an
// entity = one arm here (+ one row in Item.spec if it is an item). The old per-question
// switches (colliderShape/modelSpec/hasHealth/expectsModel) are now one-line reads.
pub const Spec = struct {
    collider: ?ColliderShape,
    model: ModelSpec,
    // TEMP-COMMENT: per-entity icon texture path; null = none yet (defaulted so arms can
    // just omit it — generated icons for enemies etc. can fill these in later).
    icon: ?[]const u8 = null,
    has_health: bool,
    expects_model: bool,
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
            .collider = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
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
        },
        .planet => .{
            .collider = null,
            .model = .{ .key = "planet", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = true,
        },
        .teleporter => .{
            .collider = .{ .box = .{ .x = 1, .y = 5, .z = 1 } },
            .model = .{ .key = "objects/pillar.glb", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = false,
        },
        .lootbox => .{
            .collider = .{ .box = .{ .x = 1, .y = 1, .z = 1 } },
            .model = .{ .key = "objects/lootbox.glb", .skinned = false, .clip_names = null },
            .has_health = false,
            .expects_model = true,
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
                .collider = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
                .model = .{ .key = "objects/Tubloid.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack" } },
                .has_health = true,
                .expects_model = true,
            },
            .tubloida => .{
                .collider = .{ .capsule = .{ .half_heigth = 0.3, .radius = 0.5 } },
                .model = .{ .key = "objects/Tubloida.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack_range" } },
                .has_health = true,
                .expects_model = true,
            },
            .bloorpLord => .{
                .collider = .{ .capsule = .{ .half_heigth = 2, .radius = 2 } },
                .model = .{ .key = "objects/BloorpLord.glb", .offset = enemy_model_offset, .skinned = true, .clip_names = .{
                    .idle = "Idle",
                    .walk = "Walking",
                    .attack = "Spawn_Enemy",
                } },
                .has_health = true,
                .expects_model = true,
            },
        },
        // TEMP-COMMENT: entity-generic parts (collider, flags) written once for ALL items;
        // the per-item part (model) delegates to the item row. New item = zero edits here.
        .item => |item_kind| .{
            .collider = .{ .box = .{ .x = 1, .y = 1, .z = 1 } },
            .model = .{ .key = Item.spec(item_kind).model, .skinned = false, .clip_names = null },
            .icon = Item.spec(item_kind).icon,
            .has_health = false,
            .expects_model = true,
        },
    };
}

// TEMP-COMMENT: every concrete Kind value (union payloads expanded) so the client can loop
// them once at init and load every model — no per-kind enum anywhere client-side.
pub const all_kinds: []const Kind = blk: {
    var kinds: []const Kind = &.{ .unknown, .player, .planet, .teleporter, .lootbox, .projectile_cube, .projectile_rocket };
    for (std.enums.values(EnemyKind)) |enemy_kind| kinds = kinds ++ .{Kind{ .enemy = enemy_kind }};
    for (std.enums.values(Item.Kind)) |item_kind| kinds = kinds ++ .{Kind{ .item = item_kind }};
    break :blk kinds;
};

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
