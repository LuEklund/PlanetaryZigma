const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("../Renderer/Vulkan/Shader.zig");
const World = @import("../World.zig");

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

pub fn spawnQuad(world: *World, effect: Shader.Kind, origin: nz.Vec3(f32)) void {
    std.debug.assert(Shader.particleInfo(effect).topology == .quad);
    insert(&world.emitters, .{
        .effect = effect,
        .origin = origin,
        .target = origin,
        .spawn_time = world.elapsed_time,
        .owner = .none,
        .last_seen = world.elapsed_time,
    }, world.elapsed_time);
}

pub fn spawnRibbon(world: *World, effect: Shader.Kind, from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    std.debug.assert(Shader.particleInfo(effect).topology == .ribbon);
    insert(&world.emitters, .{
        .effect = effect,
        .origin = from,
        .target = to,
        .spawn_time = world.elapsed_time,
        .owner = .none,
        .last_seen = world.elapsed_time,
    }, world.elapsed_time);
}

pub fn keepAlive(world: *World, effect: Shader.Kind, owner: shared.entity.Id, origin: nz.Vec3(f32)) void {
    std.debug.assert(Shader.particleInfo(effect).duration == null);
    for (&world.emitters) |*emitter| {
        if (emitter.owner != owner or emitter.effect != effect) continue;
        emitter.origin = origin;
        emitter.target = origin;
        emitter.last_seen = world.elapsed_time;
        return;
    }
    insert(&world.emitters, .{
        .effect = effect,
        .origin = origin,
        .target = origin,
        .spawn_time = world.elapsed_time,
        .owner = owner,
        .last_seen = world.elapsed_time,
    }, world.elapsed_time);
}

pub fn update(world: *World) void {
    for (world.entities.values()) |*entity| {
        if (entity.kind != .item) continue;
        const offset = nz.vec.scale(nz.vec.normalize(entity.transform.position), 0.5);
        keepAlive(world, .item_effect, entity.id, entity.transform.position - offset);
    }
}
