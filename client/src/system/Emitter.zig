const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("../Renderer/Vulkan/Shader.zig");

const Emitter = @This();

pub const max_emitters: u32 = 256;
pub const max_particles_per_effect: u32 = 64;

comptime {
    for (std.enums.values(Shader.Kind)) |kind| {
        const info = Shader.get(kind).particle orelse continue;
        if (info.particle_count > max_particles_per_effect) @compileError(
            "particle_count exceeds max_particles_per_effect: " ++ @tagName(kind),
        );
    }
}

effect: Shader.Kind,
origin: nz.Vec3(f32),
target: nz.Vec3(f32),
spawn_time: f32,
owner: shared.entity.Id,
index: u32,
last_seen: f32,

pub const List = [max_emitters]Emitter;

pub const free_spawn_time: f32 = -1.0e9;
const refresh_timeout: f32 = 0.25;

pub fn alive(self: Emitter, elapsed_time: f32) bool {
    const duration = Shader.particleInfo(self.effect).duration orelse
        return elapsed_time - self.last_seen < refresh_timeout;
    return elapsed_time - self.spawn_time < duration;
}

fn claim(list: *List, emitter: Emitter, elapsed_time: f32) void {
    var oldest: *Emitter = &list[0];
    for (list) |*slot| {
        if (!slot.alive(elapsed_time)) {
            slot.* = emitter;
            return;
        }
        if (slot.spawn_time < oldest.spawn_time) oldest = slot;
    }
    oldest.* = emitter;
}

pub fn spawnQuad(list: *List, effect: Shader.Kind, origin: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(Shader.particleInfo(effect).topology == .quad);
    claim(list, .{
        .effect = effect,
        .origin = origin,
        .target = origin,
        .spawn_time = elapsed_time,
        .owner = .none,
        .index = 0,
        .last_seen = elapsed_time,
    }, elapsed_time);
}

pub fn spawnRibbon(list: *List, effect: Shader.Kind, from: nz.Vec3(f32), to: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(Shader.particleInfo(effect).topology == .ribbon);
    claim(list, .{
        .effect = effect,
        .origin = from,
        .target = to,
        .spawn_time = elapsed_time,
        .owner = .none,
        .index = 0,
        .last_seen = elapsed_time,
    }, elapsed_time);
}

pub fn refresh(list: *List, effect: Shader.Kind, owner: shared.entity.Id, index: u32, origin: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(Shader.particleInfo(effect).duration == null);
    for (list) |*slot| {
        if (slot.owner != owner or slot.index != index or slot.effect != effect) continue;
        slot.origin = origin;
        slot.target = origin;
        slot.last_seen = elapsed_time;
        return;
    }
    claim(list, .{
        .effect = effect,
        .origin = origin,
        .target = origin,
        .spawn_time = elapsed_time,
        .owner = owner,
        .index = index,
        .last_seen = elapsed_time,
    }, elapsed_time);
}
