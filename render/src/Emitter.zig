const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("Renderer/Vulkan/Shader.zig");

const Emitter = @This();

pub const max_emitters: u32 = 1024;

effect: Shader.Kind,
origin: nz.Vec3(f32),
target: nz.Vec3(f32),
spawn_time: f32,
owner: shared.entity.Id,
last_seen: f32,

pub const List = [max_emitters]Emitter;

const free_spawn_time: f32 = -1.0e9;
const refresh_timeout: f32 = 0.25;

pub const free: Emitter = .{
    .effect = .explosion,
    .origin = .{ 0, 0, 0 },
    .target = .{ 0, 0, 0 },
    .spawn_time = free_spawn_time,
    .owner = .none,
    .last_seen = free_spawn_time,
};

pub fn alive(self: Emitter, elapsed_time: f32) bool {
    const duration = Shader.particleInfo(self.effect).duration orelse
        return elapsed_time - self.last_seen < refresh_timeout;
    return elapsed_time - self.spawn_time < duration;
}

fn insert(list: *List, new_emitter: Emitter, elapsed_time: f32) void {
    var oldest: *Emitter = &list[0];
    for (list) |*emitter| {
        if (!emitter.alive(elapsed_time)) {
            emitter.* = new_emitter;
            return;
        }
        if (emitter.spawn_time < oldest.spawn_time) oldest = emitter;
    }
    oldest.* = new_emitter;
}

pub const Spawn = struct {
    effect: Shader.Kind,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
};

pub fn spawn(list: *List, request: Spawn, elapsed_time: f32) void {
    insert(list, .{
        .effect = request.effect,
        .origin = request.origin,
        .target = request.target,
        .spawn_time = elapsed_time,
        .owner = .none,
        .last_seen = elapsed_time,
    }, elapsed_time);
}

pub fn keepAlive(list: *List, effect: Shader.Kind, owner: shared.entity.Id, origin: nz.Vec3(f32), elapsed_time: f32) void {
    std.debug.assert(Shader.particleInfo(effect).duration == null);
    for (list) |*emitter| {
        if (emitter.owner != owner or emitter.effect != effect) continue;
        emitter.origin = origin;
        emitter.target = origin;
        emitter.last_seen = elapsed_time;
        return;
    }
    insert(list, .{
        .effect = effect,
        .origin = origin,
        .target = origin,
        .spawn_time = elapsed_time,
        .owner = owner,
        .last_seen = elapsed_time,
    }, elapsed_time);
}
