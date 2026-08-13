const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const graphics = @import("graphics");
const World = @import("../World.zig");

const look_pitch_sign: f32 = -1;
const look_yaw_sign: f32 = 1;
const look_yaw_deadzone: f32 = 0.05;

pub fn update(world: *World, animator: *graphics.Animator, models: *graphics.Assets.Models) !void {
    var dying_index: usize = 0;
    while (dying_index < world.dying.items.len) {
        const corpse = &world.dying.items[dying_index];
        corpse.elapsed += world.delta_time;
        if (corpse.elapsed < models.rig(models.get(corpse.kind)).death_duration) {
            dying_index += 1;
            continue;
        }
        animator.destroy(corpse.animation);
        _ = world.dying.swapRemove(dying_index);
    }

    for (world.entities.values()) |*entity| {
        if (entity.animation == .none) entity.animation = try animator.create(if (entity.kind == .item_pickup) models.getItem(entity.item.?) else models.get(entity.kind), models);
        const loop = shared.entity.animationLoop(
            if (entity.motion.update) |update_motion| update_motion.velocity else @splat(0),
            entity.stun_time,
            if (entity.max_health > 0 and entity.health <= 0) .death else entity.override_animation_loop,
        );
        const rig = models.rig(models.get(entity.kind));
        animator.setLoop(entity.animation, rig.loop_clips.get(loop), if (loop == .death) .hold_last else .loop);
        animator.setAim(entity.animation, if (entity.id == world.player_id) aimAt(entity.transform.rotation, world) else null);
    }

    for (world.dying.items) |corpse| {
        animator.setLoop(corpse.animation, models.rig(models.get(corpse.kind)).loop_clips.get(.death), .hold_last);
    }
    for (world.action_events.items) |action_event| {
        const entity = world.getPtr(action_event.id) orelse continue;
        if (models.rig(models.get(entity.kind)).action_clips.get(action_event.action)) |clip|
            animator.playOverlay(entity.animation, clip, models);
    }
    try animator.advance(world.delta_time, models);
}

fn aimAt(entity_rotation: nz.quat.Hamiltonian(f32), world: *const World) graphics.Animator.Aim {
    var yaw_offset = entity_rotation.conjugate().mul(world.camera.yaw_rotation);
    if (yaw_offset.w < 0) yaw_offset = .{ .w = -yaw_offset.w, .x = -yaw_offset.x, .y = -yaw_offset.y, .z = -yaw_offset.z };
    var yaw = std.math.clamp(2 * std.math.atan2(yaw_offset.y, yaw_offset.w) * look_yaw_sign, -1.2, 1.2);
    if (@abs(yaw) < look_yaw_deadzone) yaw = 0;
    return .{
        .pitch = std.math.clamp(world.camera.pitch * look_pitch_sign, -1.0, 1.0),
        .yaw = yaw,
    };
}
