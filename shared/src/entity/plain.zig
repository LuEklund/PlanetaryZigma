const entity = @import("../entity.zig");
const Spec = entity.Spec;

pub const unknown: Spec = .{
    .collider = null,
    .model = null,
};

pub const player: Spec = .{
    .collider = .{
        .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.3 } },
        .motion = .dynamic,
        .layer = .moving,
    },
    .model = .{
        .path = "objects/benbozo.glb",
        .offset = .{ .position = .{ 0, -0.5, 0 }, .rotation = entity.face_camera },
        .loop_clips = .initDefault(entity.no_clip, .{
            .idle = "Idle",
            .walk = "Run",
            .death = "Death",
        }),
        .look_node_names = .{ .spine = "mixamorig:Spine2", .neck = "mixamorig:Neck", .head = null },
        .overlay_root_name = "mixamorig:Spine1",
    },
    .skills = .initDefault(entity.no_skill, .{
        .primary = .{ .skill = .shoot, .range = 10, .clip = "Run" },
        .secondary = .{ .skill = .spread_shot },
        .utility = .{ .skill = .dash },
        .equipment = .{ .skill = .use_equipment },
    }),
    .currency = 100,
};

pub const teleporter: Spec = .{
    .collider = .{
        .shape = .{ .box = .{ .x = 1, .y = 5, .z = 1 } },
        .motion = .static,
        .layer = .non_moving,
    },
    .model = .{ .path = "objects/pillar.glb", .loop_clips = null },
};

pub const lootbox: Spec = .{
    .collider = .{
        .shape = .{ .box = .{ .x = 0.6, .y = 0.6, .z = 0.6 } },
        .motion = .static,
        .layer = .moving,
    },
    .model = .{ .path = "objects/lootbox.glb", .loop_clips = null },
    .death_duration = 0.35,
    .currency = 25,
};

/// Placeholder look: the pillar model scaled down (needs a shrine model from Lucas).
const shrine_model: entity.ModelSpec = .{
    .path = "objects/pillar.glb",
    .offset = .{ .scale = .{ 0.35, 0.35, 0.35 } },
    .loop_clips = null,
};
const shrine_collider: entity.Collider = .{
    .shape = .{ .box = .{ .x = 0.6, .y = 1.6, .z = 0.6 } },
    .motion = .static,
    .layer = .moving,
};

/// RoR2 Shrine of Combat: free, summons a wave right away.
pub const shrine_combat: Spec = .{ .collider = shrine_collider, .model = shrine_model };
/// RoR2 Shrine of the Mountain: free, the teleporter boss gets twice the credits and drops.
pub const shrine_mountain: Spec = .{ .collider = shrine_collider, .model = shrine_model };
/// RoR2 Shrine of Chance: pay gold, 45% to fail; price goes up after each try.
pub const shrine_chance: Spec = .{ .collider = shrine_collider, .model = shrine_model, .currency = 17 };

pub const platform: Spec = .{
    .collider = .{
        .shape = .{ .box = .{ .x = 20, .y = 0.5, .z = 20 } },
        .motion = .static,
        .layer = .non_moving,
    },
    .model = null,
};

pub const target_dummy: Spec = .{
    .collider = .{
        .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } },
        .motion = .static,
        .layer = .non_moving,
    },
    .model = .{ .path = "objects/tubloid.glb", .offset = entity.enemy_model_offset, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "idle",
        .walk = "walk",
        .death = "Death",
    }) },
    .base_stats = .initDefault(0, .{ .health = 1000 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .melee, .clip = "attack" } }),
};

pub const item_pickup: Spec = .{
    .collider = .{
        .shape = .{ .box = .{ .x = 1, .y = 1, .z = 1 } },
        .motion = .dynamic,
        .layer = .planet_only,
    },
    .model = null,
    .spawn_duration = 0.35,
};

pub const projectile_cube: Spec = .{
    .collider = null,
    .model = null,
    .base_stats = .initDefault(0, .{ .health = 1 }),
};

pub const projectile_heal: Spec = .{
    .collider = null,
    .model = null,
    .base_stats = .initDefault(0, .{ .health = 1 }),
};

pub const projectile_rocket: Spec = .{
    .collider = null,
    .model = .{ .path = "objects/rocket.glb", .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 1 }),
};
