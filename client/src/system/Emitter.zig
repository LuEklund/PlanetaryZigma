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

pub const List = [max_emitters]Emitter;

const free_spawn_time: f32 = -1.0e9;

pub fn initList() List {
    return @splat(.{
        .effect = .explosion,
        .origin = .{ 0, 0, 0 },
        .target = .{ 0, 0, 0 },
        .spawn_time = free_spawn_time,
    });
}

pub fn alive(self: Emitter, elapsed_time: f32) bool {
    return elapsed_time - self.spawn_time < Shader.particleInfo(self.effect).duration;
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
    }, elapsed_time);
}

pub fn spawnRibbon(list: *List, effect: Shader.Kind, from: nz.Vec3(f32), to: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(Shader.particleInfo(effect).topology == .ribbon);
    claim(list, .{
        .effect = effect,
        .origin = from,
        .target = to,
        .spawn_time = elapsed_time,
    }, elapsed_time);
}
