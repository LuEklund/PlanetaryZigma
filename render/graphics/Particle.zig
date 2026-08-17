const std = @import("std");
const nz = @import("numz");
const DrawList = @import("renderer_contract").DrawList;
const ParticleEffect = @import("renderer_contract").ParticleEffect;
const effects = @import("renderer_contract").effects;

const Particle = @This();

pub const max_emitters: u32 = DrawList.max_emitters;

emitters: [max_emitters]Emitter,

pub const Emitter = struct {
    effect: ParticleEffect,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
    spawn_time: f32,
    owner: u64,
    last_seen: f32,

    const free_spawn_time: f32 = -1.0e9;
    const refresh_timeout: f32 = 0.25;

    pub const free: Emitter = .{
        .effect = .explosion_puffs,
        .origin = .{ 0, 0, 0 },
        .target = .{ 0, 0, 0 },
        .spawn_time = free_spawn_time,
        .owner = 0,
        .last_seen = free_spawn_time,
    };

    pub fn alive(self: Emitter, elapsed_time: f32) bool {
        const lifetime = effects.get(self.effect).lifetime;
        if (lifetime == 0) return elapsed_time - self.last_seen < refresh_timeout;
        return elapsed_time - self.spawn_time < lifetime;
    }
};

pub const Spawn = struct {
    effect: ParticleEffect,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
};

pub fn clear(self: *Particle) void {
    self.emitters = @splat(Emitter.free);
}

pub fn spawn(self: *Particle, request: Spawn, elapsed_time: f32) void {
    self.insert(.{
        .effect = request.effect,
        .origin = request.origin,
        .target = request.target,
        .spawn_time = elapsed_time,
        .owner = 0,
        .last_seen = elapsed_time,
    }, elapsed_time);
}

pub fn keepAlive(self: *Particle, effect: ParticleEffect, owner: u64, origin: nz.Vec3(f32), target: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(effects.get(effect).lifetime == 0);
    for (&self.emitters) |*emitter| {
        if (emitter.owner != owner or emitter.effect != effect) continue;
        emitter.origin = origin;
        emitter.target = target;
        emitter.last_seen = elapsed_time;
        return;
    }
    self.insert(.{
        .effect = effect,
        .origin = origin,
        .target = target,
        .spawn_time = elapsed_time,
        .owner = owner,
        .last_seen = elapsed_time,
    }, elapsed_time);
}

fn insert(self: *Particle, new_emitter: Emitter, elapsed_time: f32) void {
    var oldest: *Emitter = &self.emitters[0];
    for (&self.emitters) |*emitter| {
        if (!emitter.alive(elapsed_time)) {
            emitter.* = new_emitter;
            return;
        }
        if (emitter.spawn_time < oldest.spawn_time) oldest = emitter;
    }
    oldest.* = new_emitter;
}
