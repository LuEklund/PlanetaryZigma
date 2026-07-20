const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("../Renderer/Vulkan/Shader.zig");

const Emitter = @This();

effect: Shader.ParticleEffect,
origin: nz.Vec3(f32),
target: nz.Vec3(f32),
spawn_time: f32,

fn append(list: *std.ArrayList(Emitter), emitter: Emitter) void {
    if (list.items.len >= list.capacity and list.items.len > 0) {
        _ = list.swapRemove(0);
    }
    list.appendAssumeCapacity(emitter);
}

pub fn spawnRocketExplosion(list: *std.ArrayList(Emitter), position: nz.Vec3(f32), elapsed_time: f32) void {
    const surface_up = shared.planet.up(position) orelse .{ 0, 1, 0 };
    append(list, .{
        .effect = .explosion,
        .origin = position + nz.vec.scale(surface_up, 1.15),
        .target = surface_up,
        .spawn_time = elapsed_time,
    });
}

pub fn spawnLightningArc(list: *std.ArrayList(Emitter), from: nz.Vec3(f32), to: nz.Vec3(f32), elapsed_time: f32) void {
    if (nz.vec.distance(from, to) < 0.001) return;
    append(list, .{
        .effect = .lightning,
        .origin = from,
        .target = to,
        .spawn_time = elapsed_time,
    });
}

pub fn update(list: *std.ArrayList(Emitter), elapsed_time: f32) void {
    var index: usize = 0;
    while (index < list.items.len) {
        const emitter = list.items[index];
        if (elapsed_time - emitter.spawn_time >= Shader.effectSpec(emitter.effect).duration) {
            _ = list.swapRemove(index);
            continue;
        }
        index += 1;
    }
}
