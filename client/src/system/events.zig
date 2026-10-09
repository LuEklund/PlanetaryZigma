const std = @import("std");
const shared = @import("shared");
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
    for (packets) |packet| switch (packet) {
        .event => |event| switch (event) {
            .action => |action| {
                audio.play(skill_sounds.get(action.skill));
                if (action.id == world.player_id) world.controller.cooldown.set(
                    action.action,
                    world.elapsed_time,
                );
            },
            .effect => |effect| switch (effect) {
                .rocket_impact => |position| {
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
            .new_stage => |new_stage| {
                world.teleporter_id = .none;
                world.stage = new_stage;
            },
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
