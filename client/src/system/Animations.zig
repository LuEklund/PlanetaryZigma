const Animations = @This();

const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;
const Model = @import("../asset/Model.zig");
const Node = @import("../asset/Node.zig");
const AnimationClip = @import("../asset/AnimationClip.zig");
const AnimationInstance = @import("../asset/AnimationInstance.zig");

const look_pitch_sign: f32 = -1;
const look_yaw_sign: f32 = 1;
const look_yaw_deadzone: f32 = 0.05;

const item_spin_speed: f32 = 1.5;

fn easeOutBack(x: f32) f32 {
    const c1: f32 = 1.70158;
    const c3: f32 = c1 + 1.0;
    const xm1 = x - 1.0;
    return 1.0 + c3 * xm1 * xm1 * xm1 + c1 * xm1 * xm1;
}

gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator) Animations {
    return .{ .gpa = gpa };
}

pub fn updateStates(self: *Animations, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    _ = self;
    for (info.world.attack_events.items) |id| {
        const instance = instances.getPtr(id) orelse continue;
        const skeletal = if (instance.skeletal) |*skeletal| skeletal else continue;
        const model = instance.model.?;
        skeletal.playOverlay(model, model.state_clips.get(.attack));
    }
    info.world.attack_events.clearRetainingCapacity();
    for (info.world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        if (instance.skeletal == null) continue;

        var state: shared.entity.State = state: {
            const speed = if (entity.motion.update) |update_motion| nz.vec.length(update_motion.velocity) else 0;
            break :state if (speed > 0.5) .walk else .idle;
        };
        state = if (entity.flags.is_dying) .death else state;
        if (entity.override_animation_state) |override| state = override;
        instance.state = state;
    }
}

pub fn update(self: *Animations, info: *const Info, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    for (info.world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        if (instance.skeletal) |*skeletal| {
            const model = instance.model.?;
            if (model.clips.len == 0) continue;
            const clip_index = model.state_clips.get(instance.state);
            playAnimation(info, entity, skeletal, model, clip_index);
        }
    }

    for (info.world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        switch (entity.kind) {
            .lootbox => {
                if (entity.flags.is_dying and instance.deathDuration() > 0) {
                    entity.transform.scale = @splat(1.0 - std.math.clamp(instance.death_time / instance.deathDuration(), 0, 1));
                }
            },
            .item => {
                if (instance.spawn_time < instance.spawnDuration()) {
                    instance.spawn_time += info.delta_time;
                    entity.transform.scale = @splat(0.1 + 0.9 * easeOutBack(std.math.clamp(instance.spawn_time / instance.spawnDuration(), 0, 1)));
                }
                if (entity.motion.update) |*update_motion| {
                    const spun = nz.Quat(f32).fromVec(update_motion.rotation)
                        .mul(nz.Quat(f32).angleAxis(item_spin_speed * info.delta_time, .{ 0, 1, 0 }))
                        .normalize();
                    update_motion.rotation = spun.toVec();
                }
            },
            else => {},
        }
    }
}

fn playAnimation(info: *const Info, entity: *system.Entity, skeletal: *AnimationInstance.Skeletal, model: *Model, clip_index: usize) void {
    if (clip_index != skeletal.player.active) {
        skeletal.playClip(model, clip_index);
    }

    if (skeletal.overlay) |*overlay| {
        overlay.current_time += info.delta_time;
        if (overlay.current_time > model.clips[overlay.active].end) {
            skeletal.overlay = null;
            skeletal.startFade();
        }
    }

    const animation = model.clips[skeletal.player.active];
    skeletal.player.current_time += info.delta_time;

    if (skeletal.player.current_time > animation.end) {
        skeletal.player.current_time -= animation.end - animation.start;
    }
    sampleClip(skeletal.nodes, animation, skeletal.player.current_time, null);
    if (skeletal.overlay) |overlay| {
        sampleClip(skeletal.nodes, model.clips[overlay.active], overlay.current_time, model.overlay_mask);
    }
    if (skeletal.fade_time > 0) {
        skeletal.fade_time -= info.delta_time;
        const alpha = @max(skeletal.fade_time, 0) / AnimationInstance.fade_duration;
        for (skeletal.nodes, skeletal.fade_joints) |*node, fade_joint| {
            node.translation = std.math.lerp(node.translation, fade_joint.translation, @as(nz.Vec3(f32), @splat(alpha)));
            node.rotation = nz.Quat(f32).slerp(node.rotation, fade_joint.rotation, alpha);
            node.scale = std.math.lerp(node.scale, fade_joint.scale, @as(nz.Vec3(f32), @splat(alpha)));
        }
    }
    var saved_look_rotations: [3]nz.Quat(f32) = undefined;
    const looking = entity.id == info.world.player_id and model.look_nodes.len > 0;
    if (looking) {
        for (model.look_nodes, 0..) |node_index, saved_index| {
            saved_look_rotations[saved_index] = skeletal.nodes[node_index].rotation;
        }
        const camera = &info.world.camera;
        const node_count: f32 = @floatFromInt(model.look_nodes.len);
        const look_pitch = std.math.clamp(camera.pitch * look_pitch_sign, -1.0, 1.0);
        var yaw_offset = entity.transform.rotation.conjugate().mul(camera.yaw_rotation);
        if (yaw_offset.w < 0) yaw_offset = .{ .w = -yaw_offset.w, .x = -yaw_offset.x, .y = -yaw_offset.y, .z = -yaw_offset.z };
        var look_yaw = std.math.clamp(2 * std.math.atan2(yaw_offset.y, yaw_offset.w) * look_yaw_sign, -1.2, 1.2);
        if (@abs(look_yaw) < look_yaw_deadzone) look_yaw = 0;
        const pitch_per_node = look_pitch / node_count;
        const yaw_per_node = look_yaw / node_count;
        for (model.look_nodes) |node_index| {
            const node = &skeletal.nodes[node_index];
            node.rotation = node.rotation
                .mul(nz.Quat(f32).angleAxis(pitch_per_node, .{ 1, 0, 0 }))
                .mul(nz.Quat(f32).angleAxis(yaw_per_node, .{ 0, 1, 0 }))
                .normalize();
        }
    }
    Model.computeMatrices(skeletal.nodes);
    if (looking) {
        for (model.look_nodes, 0..) |node_index, saved_index| {
            skeletal.nodes[node_index].rotation = saved_look_rotations[saved_index];
        }
    }
    for (model.skins, skeletal.joint_matrices) |skin, joint_matrices| {
        for (skin.joints, skin.inverse_bind_matrices.?, joint_matrices) |node_index, inverse_bind_matrix, *joint_matrix| {
            joint_matrix.* = skeletal.nodes[node_index].model_matrix.mul(inverse_bind_matrix);
        }
    }
}

fn sampleClip(nodes: []Node, animation: AnimationClip, time: f32, mask: ?[]const bool) void {
    for (animation.channels) |*channel| {
        if (mask) |masked| {
            if (!masked[channel.node]) continue;
        }
        const sampler = animation.samplers[channel.sampler_index];
        for (0..sampler.inputs.len - 1) |i| {
            const sampler_in = sampler.inputs[i];
            const sampler_in_next = sampler.inputs[i + 1];
            if (time >= sampler_in and time <= sampler_in_next) {
                const interpolate_value: f32 = (time - sampler_in) / (sampler_in_next - sampler_in);
                const node = &nodes[channel.node];
                const sampler_out = sampler.outputs[i];
                const sampler_out_next = sampler.outputs[i + 1];
                switch (channel.path) {
                    .translation => {
                        const translation = std.math.lerp(
                            sampler_out,
                            sampler_out_next,
                            @as(nz.Vec4(f32), @splat(interpolate_value)),
                        );
                        node.translation = .{ translation[0], translation[1], translation[2] };
                    },
                    .rotation => node.rotation = nz.Quat(f32).slerp(
                        .{ .w = sampler_out[3], .x = sampler_out[0], .y = sampler_out[1], .z = sampler_out[2] },
                        .{ .w = sampler_out_next[3], .x = sampler_out_next[0], .y = sampler_out_next[1], .z = sampler_out_next[2] },
                        interpolate_value,
                    ),
                    .scale => {
                        const scale = std.math.lerp(
                            sampler_out,
                            sampler_out_next,
                            @as(nz.Vec4(f32), @splat(interpolate_value)),
                        );
                        node.scale = .{ scale[0], scale[1], scale[2] };
                    },
                }
            }
        }
    }
}
