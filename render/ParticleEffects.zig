const std = @import("std");

pub const Placement = enum(u32) { burst, line, orbit };
pub const Motion = enum(u32) { ballistic, along_path };
pub const ParticleEffect = enum(u32) {
    explosion_puffs,
    explosion_sparks,
    lightning,
    item_effect,

    pub const count: usize = @typeInfo(ParticleEffect).@"enum".fields.len;
};
pub const EffectParams = extern struct {
    placement: u32,
    motion: u32,
    count: u32,
    lifetime: f32,
    speed: f32,
    radius: f32,
    jitter: f32,
    arch_height: f32,
    spin: f32,
    size_start: f32,
    size_end: f32,
    strands: u32,
    ramp_steps: [4]f32,
    color_ramp: [5][4]f32,
};

pub fn instancesPerEmitter(params: EffectParams) u32 {
    return switch (@as(Placement, @enumFromInt(params.placement))) {
        .burst => params.count,
        .line => params.count - 1,
        .orbit => params.count - params.strands,
    };
}

pub const effect_params: std.EnumArray(ParticleEffect, EffectParams) = .init(.{
    .explosion_puffs = .{
        .placement = @intFromEnum(Placement.burst),
        .motion = @intFromEnum(Motion.ballistic),
        .count = 8,
        .lifetime = 0.8,
        .speed = 0.35,
        .radius = 0.45,
        .jitter = 0.0,
        .arch_height = 1.15,
        .spin = 0.0,
        .size_start = 2.2,
        .size_end = 0.0,
        .strands = 0,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
        },
    },
    .explosion_sparks = .{
        .placement = @intFromEnum(Placement.burst),
        .motion = @intFromEnum(Motion.ballistic),
        .count = 32,
        .lifetime = 0.5,
        .speed = 5.5,
        .radius = 0.1,
        .jitter = 0.0,
        .arch_height = 1.15,
        .spin = 0.0,
        .size_start = 0.28,
        .size_end = 0.0,
        .strands = 0,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
        },
    },
    .lightning = .{
        .placement = @intFromEnum(Placement.line),
        .motion = @intFromEnum(Motion.along_path),
        .count = 64,
        .lifetime = 0.3,
        .speed = 0.0,
        .radius = 0.0,
        .jitter = 0.55,
        .arch_height = 0.35,
        .spin = 0.0,
        .size_start = 0.55,
        .size_end = 0.0,
        .strands = 8,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 0.431, 0.627, 1.0, 0.45 },
            .{ 0.431, 0.627, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
        },
    },
    .item_effect = .{
        .placement = @intFromEnum(Placement.orbit),
        .motion = @intFromEnum(Motion.along_path),
        .count = 154,
        .lifetime = 0.0,
        .speed = 1.15,
        .radius = 0.8,
        .jitter = 0.03,
        .arch_height = 1.1,
        .spin = 0.55,
        .size_start = 0.13,
        .size_end = 0.13,
        .strands = 7,
        .ramp_steps = .{ 0.26, 0.42, 0.58, 0.74 },
        .color_ramp = .{
            .{ 0.03, 0.14, 0.07, 0.8 },
            .{ 0.07, 0.32, 0.15, 0.8 },
            .{ 0.16, 0.58, 0.26, 0.8 },
            .{ 0.38, 0.82, 0.38, 0.8 },
            .{ 0.74, 1.0, 0.66, 0.8 },
        },
    },
});
