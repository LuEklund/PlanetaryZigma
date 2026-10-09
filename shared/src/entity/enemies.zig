const entity = @import("../entity.zig");
const Spec = entity.Spec;

pub const tubloid: Spec = .{
    .behavior = .chase,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/tubloid.glb", .offset = entity.enemy_model_offset, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "idle",
        .walk = "walk",
        .death = "Death",
    }) },
    .base_stats = .initDefault(0, .{ .health = 25, .speed = 3, .damage = 10, .primary_cooldown = 1 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .melee, .range = 2, .clip = "attack" } }),
    .currency = 5,
};

pub const tubloida: Spec = .{
    .behavior = .chase,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/tubloida.glb", .offset = entity.enemy_model_offset, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "idle",
        .walk = "walk",
        .death = "Death",
    }) },
    .base_stats = .initDefault(0, .{ .health = 10, .speed = 3, .damage = 5, .primary_cooldown = 5 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .shoot_cube, .range = 10, .clip = "attack_range" } }),
    .currency = 7,
};

pub const bloorp_lord: Spec = .{
    .behavior = .{ .hover = 14 },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 1.5, .radius = 4.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/bloorplord.glb", .offset = .{ .position = .{ 0, -10, 0 }, .rotation = entity.face_camera }, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "Idle",
        .walk = "Walking",
        .death = "Death",
    }) },
    .base_stats = .initDefault(0, .{ .health = 100, .speed = 30, .damage = 10, .primary_cooldown = 0.1 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .shoot_cube, .range = 40, .clip = "Spawn_Enemy" } }),
    .currency = 100,
};

pub const hunkloid: Spec = .{
    .behavior = .leap,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.6, .radius = 1 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/hunkloid.glb", .offset = .{ .position = .{ 0, -1.8, 0 }, .rotation = entity.face_camera }, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "Idle",
        .walk = "Walk",
        .death = "Death",
    }) },
    .base_stats = .initDefault(0, .{ .health = 50, .speed = 1, .damage = 25, .primary_cooldown = 5, .utility_cooldown = 5 }),
    .skills = .initDefault(entity.no_skill, .{
        .primary = .{ .skill = .melee, .range = 3, .clip = "Attack" },
        .utility = .{ .skill = .arc_jump, .range = 12, .clip = "Secondary" },
    }),
    .currency = 30,
};

pub const blooploid: Spec = .{
    .behavior = .{ .hover = 7 },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/blooploid.glb", .offset = entity.enemy_model_offset, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 10, .speed = 10, .damage = 5, .primary_cooldown = 5 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .shoot_cube, .range = 15 } }),
    .currency = 7,
};

pub const acorn: Spec = .{
    .behavior = .plant,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.05, .radius = 0.4 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/acorn.glb", .offset = .{ .position = .{ 0, -0.4, 0 }, .rotation = entity.face_camera }, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "Idle",
        .walk = "Run",
    }) },
    .base_stats = .initDefault(0, .{ .health = 5, .speed = 10, .damage = 1, .primary_cooldown = 2 }),
    .skills = .initDefault(entity.no_skill, .{
        .primary = .{ .skill = .melee, .range = 2 },
        .utility = .{ .skill = .plant, .clip = "Planted" },
    }),
    .currency = 5,
};

pub const grass1: Spec = .{
    .behavior = .chase,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.45, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/grass1.glb", .offset = .{ .position = .{ 0, -1, 0 }, .rotation = entity.face_camera }, .loop_clips = .initDefault(entity.no_clip, .{
        .idle = "Idle",
        .walk = "Walk",
    }) },
    .base_stats = .initDefault(0, .{ .health = 30, .speed = 3, .damage = 10, .primary_cooldown = 0.75 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .melee, .range = 2, .clip = "Attack" } }),
    .currency = 25,
};

pub const grass_tank: Spec = .{
    .behavior = .{ .charge = .{ .trigger_distance = 14, .windup_seconds = 0.7, .dash_seconds = 0.6, .speed_multiplier = 5 } },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.45, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/grasstank.glb", .offset = .{ .position = .{ 0, -1, 0 }, .rotation = entity.face_camera }, .loop_clips = .initDefault(entity.no_clip, .{}) },
    .base_stats = .initDefault(0, .{ .health = 40, .speed = 4, .damage = 18, .primary_cooldown = 4 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .charge, .range = 14 } }),
    .currency = 25,
};

pub const spitter: Spec = .{
    .behavior = .{ .kite = .{ .min_distance = 10, .max_distance = 20 } },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "", .offset = entity.placeholder_model_offset, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 18, .speed = 5, .damage = 6, .primary_cooldown = 2 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .shoot_cube, .range = 25 } }),
    .currency = 12,
};

pub const wisp: Spec = .{
    .behavior = .{ .orbit = .{ .radius = 12, .height = 6 } },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.2, .radius = 0.4 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "", .offset = .{ .scale = .{ 0.35, 0.35, 0.35 } }, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 12, .speed = 8, .damage = 4, .primary_cooldown = 1.5 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .shoot_cube, .range = 20 } }),
    .currency = 10,
};

pub const mite: Spec = .{
    .behavior = .chase,
    .pack_size = 5,
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.1, .radius = 0.3 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "", .offset = .{ .scale = .{ 0.25, 0.25, 0.25 } }, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 4, .speed = 9, .damage = 3, .primary_cooldown = 0.6 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .melee, .range = 1.5 } }),
    .currency = 3,
};

pub const bomber: Spec = .{
    .behavior = .{ .fuse = .{ .fuse_seconds = 0.8, .blast_radius = 5 } },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "", .offset = .{ .scale = .{ 0.6, 0.6, 0.6 } }, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 20, .speed = 6, .damage = 30, .primary_cooldown = 1 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .explode, .range = 3 } }),
    .currency = 15,
};

pub const healer: Spec = .{
    .behavior = .{ .heal = 7 },
    .collider = .{ .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.5 } }, .motion = .dynamic, .layer = .moving },
    .model = .{ .path = "objects/healer.glb", .offset = entity.enemy_model_offset, .loop_clips = null },
    .base_stats = .initDefault(0, .{ .health = 10, .speed = 10, .damage = -1, .primary_cooldown = 0.2 }),
    .skills = .initDefault(entity.no_skill, .{ .primary = .{ .skill = .heal, .range = 15 } }),
    .currency = 7,
};
