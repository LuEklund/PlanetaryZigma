const std = @import("std");

pub const Placement = enum(u32) { burst, line, orbit, ring };
pub const Motion = enum(u32) { ballistic, along_path };
pub const Blend = enum { alpha, additive };
/// Fragment shape: soft dot, a streak stretched along its own velocity, or a thin expanding ring.
pub const Shape = enum(u32) { dot, spark, shockwave };
pub const ParticleEffect = enum(u32) {
    explosion_puffs,
    explosion_sparks,
    lightning,
    item_effect,
    tracer,
    telegraph,
    muzzle_flash,
    hit_sparks,
    shockwave,
    heal_tracer,
    spawn_puff,

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
        shape: u32,
        drag: f32,
        gravity: f32,
        glow: f32,
    };

    pub fn instancesPerEmitter(effect: Effect) u32 {
        return switch (effect.placement) {
            .burst => effect.count,
            .line => effect.count - 1,
            .orbit => |orbit| effect.count - orbit.strands,
            .ring => |ring| effect.count - ring.strands,
        };
    }

    count: u32,
    lifetime: f32,
    blend: Blend,
    size_start: f32,
    size_end: f32,
    ramp_steps: [4]f32,
    color_ramp: [5][4]f32,
    shape: Shape = .dot,
    /// Burst speed decays as e^(-drag·t) (closed form, still stateless).
    drag: f32 = 0,
    /// Pull toward the planet, m/s².
    gravity: f32 = 0,
    /// HDR multiplier: above 1 feeds the bloom.
    glow: f32 = 1,
    placement: union(Placement) {
        burst: struct { radius: f32, speed: f32, stretch: f32 },
        line: struct { jitter: f32, arch_height: f32, strands: u32 },
        orbit: struct { radius: f32, spin: f32, strands: u32, height: f32, scroll: f32, jitter: f32 },
        /// Closed circles around `origin` in the plane normal to `target - origin`, radius =
        /// its length. Chain 0 is the edge, chain 1 fills in to the edge over the lifetime.
        ring: struct { strands: u32 },
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
            .shape = @intFromEnum(effect.shape),
            .drag = effect.drag,
            .gravity = effect.gravity,
            .glow = effect.glow,
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
            .ring => |ring| {
                params.motion = @intFromEnum(Motion.along_path);
                params.strands = ring.strands;
            },
        }
        return params;
    }
};

pub const effects: std.EnumArray(ParticleEffect, Effect) = .init(.{
    .explosion_puffs = .{
        .count = 8,
        .lifetime = 0.8,
        .blend = .alpha,
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
        .blend = .additive,
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
        .shape = .spark,
        .drag = 2.5,
        .gravity = 6,
        .glow = 2.5,
        .placement = .{ .burst = .{ .radius = 0.1, .speed = 9, .stretch = 3 } },
    },
    .lightning = .{
        .count = 64,
        .lifetime = 0.3,
        .blend = .additive,
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
        .glow = 3,
        .placement = .{ .line = .{ .jitter = 0.55, .arch_height = 0.35, .strands = 8 } },
    },
    .item_effect = .{
        .count = 154,
        .lifetime = 0.0,
        .blend = .alpha,
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
        .placement = .{
            .orbit = .{
                .radius = 0.8,
                .spin = 0.55,
                .strands = 7,
                .height = 1.1,
                .scroll = 1.15,
                .jitter = 0.03,
            },
        },
    },
    .tracer = .{
        .count = 1,
        .lifetime = 0.0,
        .blend = .additive,
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
        .glow = 2.5,
        .placement = .{ .burst = .{ .radius = 0.0, .speed = 0.0, .stretch = 6.0 } },
    },
    .telegraph = .{
        .count = 2 * 49,
        .lifetime = 1.0,
        .blend = .additive,
        .size_start = 0.25,
        .size_end = 0.35,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.25, 0.1, 0.8 },
            .{ 1.0, 0.3, 0.1, 0.9 },
            .{ 1.0, 0.4, 0.15, 1.0 },
            .{ 1.0, 0.5, 0.2, 1.0 },
            .{ 1.0, 0.6, 0.3, 1.0 },
        },
        .glow = 1.5,
        .placement = .{ .ring = .{ .strands = 2 } },
    },
    .muzzle_flash = .{
        .count = 6,
        .lifetime = 0.09,
        .blend = .additive,
        .size_start = 0.7,
        .size_end = 0.1,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.55, 0.15, 1.0 },
            .{ 1.0, 0.75, 0.3, 1.0 },
            .{ 1.0, 0.9, 0.55, 1.0 },
            .{ 1.0, 1.0, 0.85, 1.0 },
            .{ 1.0, 1.0, 1.0, 1.0 },
        },
        .glow = 3,
        .placement = .{ .burst = .{ .radius = 0.05, .speed = 3, .stretch = 0 } },
    },
    .hit_sparks = .{
        .count = 10,
        .lifetime = 0.35,
        .blend = .additive,
        .size_start = 0.12,
        .size_end = 0.02,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.35, 0.1, 1.0 },
            .{ 1.0, 0.55, 0.2, 1.0 },
            .{ 1.0, 0.8, 0.4, 1.0 },
            .{ 1.0, 0.95, 0.7, 1.0 },
            .{ 1.0, 1.0, 1.0, 1.0 },
        },
        .shape = .spark,
        .drag = 5,
        .gravity = 12,
        .glow = 2.5,
        .placement = .{ .burst = .{ .radius = 0.05, .speed = 10, .stretch = 4 } },
    },
    .shockwave = .{
        .count = 1,
        .lifetime = 0.35,
        .blend = .additive,
        .size_start = 0.5,
        .size_end = 9,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 1.0, 0.5, 0.2, 0.6 },
            .{ 1.0, 0.6, 0.3, 0.7 },
            .{ 1.0, 0.8, 0.5, 0.8 },
            .{ 1.0, 0.9, 0.7, 0.9 },
            .{ 1.0, 1.0, 1.0, 1.0 },
        },
        .shape = .shockwave,
        .glow = 1.8,
        .placement = .{ .burst = .{ .radius = 0, .speed = 0, .stretch = 0 } },
    },
    .heal_tracer = .{
        .count = 1,
        .lifetime = 0.0,
        .blend = .additive,
        .size_start = 0.18,
        .size_end = 0.18,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 0.3, 1.0, 0.45, 1.0 },
            .{ 0.3, 1.0, 0.45, 1.0 },
            .{ 0.6, 1.0, 0.6, 1.0 },
            .{ 0.6, 1.0, 0.6, 1.0 },
            .{ 0.8, 1.0, 0.8, 1.0 },
        },
        .glow = 2,
        .placement = .{ .burst = .{ .radius = 0.0, .speed = 0.0, .stretch = 6.0 } },
    },
    .spawn_puff = .{
        .count = 14,
        .lifetime = 0.9,
        .blend = .alpha,
        .size_start = 1.6,
        .size_end = 0.2,
        .ramp_steps = .{ 0.2, 0.4, 0.6, 0.8 },
        .color_ramp = .{
            .{ 0.12, 0.05, 0.18, 0.7 },
            .{ 0.22, 0.08, 0.32, 0.8 },
            .{ 0.35, 0.15, 0.5, 0.9 },
            .{ 0.55, 0.3, 0.75, 0.9 },
            .{ 0.8, 0.6, 1.0, 1.0 },
        },
        .drag = 3,
        .gravity = -1.5,
        .placement = .{ .burst = .{ .radius = 0.6, .speed = 3, .stretch = 0 } },
    },
});
