const std = @import("std");

pub const Placement = enum(u32) { burst, line, orbit };
pub const Motion = enum(u32) { ballistic, along_path };
pub const ParticleEffect = enum(u32) {
    explosion_puffs,
    explosion_sparks,
    lightning,
    item_effect,
    tracer,

    pub const count: usize = @typeInfo(ParticleEffect).@"enum".fields.len;
};
pub const Effect = struct {
    pub const GPU = extern struct {
        placement: u32,
        motion: u32,
        count: u32,
        lifetime: f32, // 0.0 = keepAlive
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
        stretch: f32,
    };

    pub fn instancesPerEmitter(effect: Effect) u32 {
        return switch (effect.placement) {
            .burst => effect.count,
            .line => effect.count - 1,
            .orbit => |orbit| effect.count - orbit.strands,
        };
    }

    count: u32,
    lifetime: f32,
    size_start: f32,
    size_end: f32,
    ramp_steps: [4]f32,
    color_ramp: [5][4]f32,
    placement: union(Placement) {
        burst: struct { radius: f32, speed: f32, stretch: f32 },
        line: struct { jitter: f32, arch_height: f32, strands: u32 },
        orbit: struct { radius: f32, spin: f32, strands: u32, height: f32, scroll: f32, jitter: f32 },
    },

    pub fn toGPU(effect: Effect) GPU {
        var params: GPU = .{
            .placement = 0,
            .motion = 0,
            .count = effect.count,
            .lifetime = effect.lifetime,
            .speed = 0,
            .radius = 0,
            .jitter = 0,
            .arch_height = 0,
            .spin = 0,
            .size_start = effect.size_start,
            .size_end = effect.size_end,
            .strands = 0,
            .stretch = 0,
            .ramp_steps = effect.ramp_steps,
            .color_ramp = effect.color_ramp,
        };
        params.placement = @intFromEnum(effect.placement);
        switch (effect.placement) {
            .burst => |burst| {
                params.motion = @intFromEnum(Motion.ballistic);
                params.radius = burst.radius;
                params.speed = burst.speed;
                params.stretch = burst.stretch;
            },
            .line => |line| {
                params.motion = @intFromEnum(Motion.along_path);
                params.jitter = line.jitter;
                params.arch_height = line.arch_height;
                params.strands = line.strands;
            },
            .orbit => |orbit| {
                params.motion = @intFromEnum(Motion.along_path);
                params.radius = orbit.radius;
                params.spin = orbit.spin;
                params.strands = orbit.strands;
                params.arch_height = orbit.height;
                params.speed = orbit.scroll;
                params.jitter = orbit.jitter;
            },
        }
        return params;
    }
};

pub const effects: std.EnumArray(ParticleEffect, Effect) = .init(.{
    .explosion_puffs = .{
        .count = 8,
        .lifetime = 0.8,
        .size_start = 2.2,
        .size_end = 0.0,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
        },
        .placement = .{ .burst = .{ .radius = 0.45, .speed = 0.35, .stretch = 0 } },
    },
    .explosion_sparks = .{
        .count = 32,
        .lifetime = 0.5,
        .size_start = 0.28,
        .size_end = 0.0,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.275, 0.047, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
            .{ 1.0, 0.922, 0.188, 1.0 },
        },
        .placement = .{ .burst = .{ .radius = 0.1, .speed = 5.5, .stretch = 0 } },
    },
    .lightning = .{
        .count = 64,
        .lifetime = 0.3,
        .size_start = 0.55,
        .size_end = 0.0,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 0.431, 0.627, 1.0, 0.45 },
            .{ 0.431, 0.627, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
            .{ 1.0, 1.0, 1.0, 0.45 },
        },
        .placement = .{ .line = .{ .jitter = 0.55, .arch_height = 0.35, .strands = 8 } },
    },
    .item_effect = .{
        .count = 154,
        .lifetime = 0.0,
        .size_start = 0.13,
        .size_end = 0.13,
        .ramp_steps = .{ 0.26, 0.42, 0.58, 0.74 },
        .color_ramp = .{
            .{ 0.03, 0.14, 0.07, 0.8 },
            .{ 0.07, 0.32, 0.15, 0.8 },
            .{ 0.16, 0.58, 0.26, 0.8 },
            .{ 0.38, 0.82, 0.38, 0.8 },
            .{ 0.74, 1.0, 0.66, 0.8 },
        },
        .placement = .{ .orbit = .{ .radius = 0.8, .spin = 0.55, .strands = 7, .height = 1.1, .scroll = 1.15, .jitter = 0.03 } },
    },
    .tracer = .{
        .count = 1,
        .lifetime = 0.0,
        .size_start = 0.15,
        .size_end = 0.15,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.95, 0.6, 1.0 },
            .{ 1.0, 0.95, 0.6, 1.0 },
            .{ 1.0, 0.8, 0.3, 1.0 },
            .{ 1.0, 0.8, 0.3, 1.0 },
            .{ 1.0, 0.8, 0.3, 1.0 },
        },
        .placement = .{ .burst = .{ .radius = 0.0, .speed = 0.0, .stretch = 6.0 } },
    },
});
