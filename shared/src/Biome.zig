const Biome = @This();

const std = @import("std");
const entity = @import("entity.zig");
const Field = @import("planet/Field.zig");

name: []const u8,
field_scale: [Field.fields.len]f32,
frequency_scale: f32,
low_color: [3]f32,
high_color: [3]f32,
steep_color: [3]f32,
enemy_weights: std.EnumArray(entity.EnemyKind, u8),

pub const rows = struct {
    pub const coral: Biome = .{
        .name = "Coral Shelf",
        .field_scale = .{ 1, 1, 1 },
        .frequency_scale = 1,
        .low_color = .{ 1, 0.35, 0.2 },
        .high_color = .{ 0.1, 0.75, 0.6 },
        .steep_color = .{ 0.55, 0.3, 0.25 },
        .enemy_weights = .initDefault(0, .{ .grass1 = 11, .tubloid = 25, .tubloida = 15, .hunkloid = 12, .healer = 12, .bloorp_lord = 7, .spitter = 8, .bomber = 6, .mite = 4 }),
    };

    pub const verdant: Biome = .{
        .name = "Verdant Hills",
        .field_scale = .{ 1, 0.5, 0.3 },
        .frequency_scale = 1.3,
        .low_color = .{ 0.3, 0.45, 0.15 },
        .high_color = .{ 0.55, 0.8, 0.3 },
        .steep_color = .{ 0.4, 0.33, 0.25 },
        .enemy_weights = .initDefault(0, .{ .grass1 = 30, .tubloid = 25, .tubloida = 10, .healer = 10, .bloorp_lord = 5, .grass_tank = 12, .mite = 8 }),
    };

    pub const frost: Biome = .{
        .name = "Frost Spires",
        .field_scale = .{ 0.6, 1, 0.4 },
        .frequency_scale = 1.6,
        .low_color = .{ 0.75, 0.82, 0.92 },
        .high_color = .{ 0.95, 0.97, 1 },
        .steep_color = .{ 0.4, 0.5, 0.65 },
        .enemy_weights = .initDefault(0, .{ .tubloida = 20, .blooploid = 20, .healer = 15, .hunkloid = 10, .bloorp_lord = 8, .wisp = 17, .spitter = 10 }),
    };

    pub const dust: Biome = .{
        .name = "Dust Basin",
        .field_scale = .{ 0.4, 0.3, 1 },
        .frequency_scale = 0.8,
        .low_color = .{ 0.75, 0.55, 0.3 },
        .high_color = .{ 0.95, 0.8, 0.5 },
        .steep_color = .{ 0.55, 0.35, 0.2 },
        .enemy_weights = .initDefault(0, .{ .hunkloid = 25, .tubloid = 15, .tubloida = 10, .healer = 8, .bloorp_lord = 10, .bomber = 14, .grass_tank = 10, .mite = 8 }),
    };
};

const row_count: usize = @typeInfo(rows).@"struct".decls.len;

const all: [row_count]Biome = table: {
    var table: [row_count]Biome = undefined;
    for (@typeInfo(rows).@"struct".decls, &table) |decl, *slot| {
        slot.* = @field(rows, decl.name);
        for (slot.field_scale) |scale| std.debug.assert(scale >= 0 and scale <= 1);
    }
    break :table table;
};

pub fn forRadius(planet_radius: u32) *const Biome {
    return &all[std.hash.int(planet_radius) % row_count];
}

pub fn pickEnemy(biome: *const Biome, random: std.Random) ?entity.EnemyKind {
    var total: u32 = 0;
    for (biome.enemy_weights.values) |weight| total += weight;
    if (total == 0) return null;
    var pick = random.uintLessThan(u32, total);
    for (std.enums.values(entity.EnemyKind)) |enemy_kind| {
        const weight = biome.enemy_weights.get(enemy_kind);
        if (pick < weight) return enemy_kind;
        pick -= weight;
    }
    unreachable;
}
