const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Audio = @import("Audio.zig");
const Particle = @import("graphics").Particle;
const World = @import("../World.zig");

pub fn apply(
    world: *World,
    packets: []const shared.net.ServerPacket,
    audio: *Audio,
    skill_sounds: *const std.EnumArray(shared.entity.Skill, Audio.Sound),
    particles: *Particle,
) void {
    for (world.damage_events.items) |hit| {
        if (hit.delta <= 0) continue;
        const up = nz.vec.normalize(hit.position);
        const point = hit.position + nz.vec.scale(up, 1);
        particles.spawn(.{ .effect = .hit_sparks, .origin = point, .target = point }, world.elapsed_time);
    }
    for (packets) |packet| switch (packet) {
        .spawn_entity => |spawn| if (spawn.kind == .enemy) {
            const position: nz.Vec3(f32) = spawn.position;
            particles.spawn(.{ .effect = .spawn_puff, .origin = position, .target = position }, world.elapsed_time);
        },
        .event => |event| switch (event) {
            .action => |action| {
                audio.play(skill_sounds.get(action.skill));
                if (firesShot(action.skill)) if (world.getPtr(action.id)) |shooter| {
                    const muzzle = shooter.transform.position + nz.vec.scale(nz.vec.normalize(shooter.transform.position), 1.2);
                    particles.spawn(.{ .effect = .muzzle_flash, .origin = muzzle, .target = muzzle }, world.elapsed_time);
                };
                if (action.id == world.player_id) world.controller.cooldown.set(
                    action.action,
                    world.elapsed_time,
                );
            },
            .effect => |effect| switch (effect) {
                .rocket_impact => |position| {
                    particles.spawn(
                        .{ .effect = .shockwave, .origin = position, .target = position },
                        world.elapsed_time,
                    );
                    particles.spawn(
                        .{ .effect = .explosion_puffs, .origin = position, .target = position },
                        world.elapsed_time,
                    );
                    particles.spawn(
                        .{ .effect = .explosion_sparks, .origin = position, .target = position },
                        world.elapsed_time,
                    );
                },
                .lightning => |bolt| for (bolt.targets) |id| {
                    const target = world.getPtr(id) orelse continue;
                    particles.spawn(
                        .{
                            .effect = .lightning,
                            .origin = bolt.start_position,
                            .target = target.transform.position,
                        },
                        world.elapsed_time,
                    );
                },
            },
            .teleport_start => if (world.getPtr(world.teleporter_id)) |entity| {
                entity.teleporter.state = .active;
            },
            .teleporter_charge => |charged| if (world.getPtr(world.teleporter_id)) |entity| {
                entity.teleporter.charged = charged;
            },
            .difficulty => |difficulty| world.difficulty = difficulty,
            .telegraph => |telegraph| {
                const up = nz.vec.normalize(telegraph.position);
                const center = world.planet.surfacePoint(up) + nz.vec.scale(up, 0.3);
                particles.spawn(.{
                    .effect = .telegraph,
                    .origin = center,
                    .target = center + nz.vec.scale(up, telegraph.radius),
                }, world.elapsed_time);
            },
            .ping => |ping| {
                world.pings[world.next_ping] = .{ .event = ping, .expires_at = world.elapsed_time + World.ping_seconds };
                world.next_ping = (world.next_ping + 1) % World.max_pings;
            },
            .new_stage => {},
            .stun => |stun| if (world.getPtr(stun.id)) |entity| {
                entity.stun_time = stun.duration;
            },
            .interact => |interact| if (world.getPtr(interact.interactor)) |entity| {
                entity.interacting = interact.interacted;
            },
        },
        else => {},
    };
}

fn firesShot(skill: shared.entity.Skill) bool {
    return switch (skill) {
        .shoot, .spread_shot, .shoot_cube, .railgun, .grenade, .artillery => true,
        else => false,
    };
}
