const Animations = @This();

const std = @import("std");
const system = @import("../System.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const World = system.World;
const nz = shared.numz;
const Model = @import("../asset/Model.zig");
const Node = @import("../asset/Node.zig");
const AnimationClip = @import("../asset/AnimationClip.zig");
const AnimationInstance = @import("../asset/AnimationInstance.zig");
const ModelLoader = @import("../Renderer/loader/ModelLoader.zig");
const FramePacket = @import("../Renderer/FramePacket.zig");

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

fn resolveModel(loader: *ModelLoader, instance: *const AnimationInstance) ?*Model {
    return loader.modelPtr(instance.model_handle orelse return null);
}

pub fn applyEvents(self: *Animations, events: []const FramePacket.RenderCommand, loader: *ModelLoader, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    for (loader.reloaded.items) |file_index| {
        const reloaded_model = &loader.entries[file_index].model;
        var instance_iterator = instances.valueIterator();
        while (instance_iterator.next()) |instance| {
            const handle = instance.model_handle orelse continue;
            if (handle != .file or handle.file != file_index) continue;
            if (instance.skeleton) |*skeleton| skeleton.deinit(self.gpa);
            instance.skeleton = if (reloaded_model.isSkinned()) try .init(self.gpa, reloaded_model) else null;
        }
    }
    loader.reloaded.clearRetainingCapacity();

    for (events) |command| switch (command) {
        .entity_spawned => |spawned| {
            if (instances.contains(spawned.id)) continue;
            const handle = loader.handleForKind(spawned.kind) orelse continue;
            const model = loader.modelPtr(handle);
            if (model) |file_model| if (file_model.isEmpty()) {
                std.log.err("model not loaded for {s}", .{@tagName(spawned.kind)});
            };
            try instances.put(spawned.id, try .init(self.gpa, handle, model));
        },
        .entity_despawned => |id| {
            if (instances.fetchRemove(id)) |removed| {
                var instance = removed.value;
                instance.deinit(self.gpa);
            }
        },
        .planet_spawned => {},
    };
}

pub fn updateStates(self: *Animations, world: *World, loader: *ModelLoader, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    _ = self;
    for (world.trigger_events.items) |trigger| {
        const instance = instances.getPtr(trigger.id) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        const model = resolveModel(loader, instance) orelse continue;
        const clip_index = model.state_clips.get(trigger.state) orelse continue;
        skeleton.playOverlay(model, clip_index);
    }
    world.trigger_events.clearRetainingCapacity();
    for (world.entities.values()) |*entity| {
        entity.stun_time = @max(0, entity.stun_time - world.delta_time);
        const instance = instances.getPtr(entity.id) orelse continue;
        if (instance.skeleton == null) continue;

        var state: shared.entity.State = state: {
            const speed = if (entity.motion.update) |update_motion| nz.vec.length(update_motion.velocity) else 0;
            break :state if (speed > 0.5) .walk else .idle;
        };
        state = if (entity.stun_time > 0) .stun else state;
        state = if (entity.flags.is_dying) .death else state;
        if (entity.override_animation_state) |override| state = override;
        instance.state = state;
    }
}

pub fn update(self: *Animations, world: *World, loader: *ModelLoader, instances: *std.AutoHashMap(shared.entity.Id, AnimationInstance)) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    for (world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        if (entity.flags.is_dying) {
            instance.death_time += world.delta_time;
        } else if (instance.death_time > 0) {
            instance.death_time = 0;
        }
        if (instance.skeleton) |*skeleton| {
            const model = resolveModel(loader, instance) orelse continue;
            playAnimation(world, entity, skeleton, model, model.state_clips.get(instance.state));
        }
    }

    for (world.entities.values()) |*entity| {
        const instance = instances.getPtr(entity.id) orelse continue;
        switch (entity.kind) {
            .lootbox => {
                if (entity.flags.is_dying and instance.deathDuration() > 0) {
                    entity.transform.scale = @splat(1.0 - std.math.clamp(instance.death_time / instance.deathDuration(), 0, 1));
                }
            },
            .item => {
                if (instance.spawn_time < instance.spawnDuration()) {
                    instance.spawn_time += world.delta_time;
                    entity.transform.scale = @splat(0.1 + 0.9 * easeOutBack(std.math.clamp(instance.spawn_time / instance.spawnDuration(), 0, 1)));
                }
                if (entity.motion.update) |*update_motion| {
                    const spun = nz.Quat(f32).fromVec(update_motion.rotation)
                        .mul(nz.Quat(f32).angleAxis(item_spin_speed * world.delta_time, .{ 0, 1, 0 }))
                        .normalize();
                    update_motion.rotation = spun.toVec();
                }
            },
            else => {},
        }
    }
}

fn playAnimation(world: *World, entity: *system.Entity, skeleton: *AnimationInstance.Skeleton, model: *Model, clip_index: ?usize) void {
    if (clip_index) |index| {
        if (index != skeleton.player.active) {
            skeleton.playClip(model, index);
        }
    }

    if (skeleton.overlay) |*overlay| {
        overlay.current_time += world.delta_time;
        if (overlay.current_time > model.clips[overlay.active].end) {
            skeleton.overlay = null;
            skeleton.startFade();
        }
    }

    if (clip_index != null) {
        const animation = model.clips[skeleton.player.active];
        skeleton.player.current_time += world.delta_time;

        if (skeleton.player.current_time > animation.end) {
            if (entity.flags.is_dying)
                skeleton.player.current_time = animation.end
            else
                skeleton.player.current_time -= animation.end - animation.start;
        }
        sampleClip(skeleton.nodes, animation, skeleton.player.current_time, null);
    } else {
        for (skeleton.nodes, model.nodes.items) |*node, bind_node| {
            node.translation = bind_node.translation;
            node.rotation = bind_node.rotation;
            node.scale = bind_node.scale;
        }
    }
    if (skeleton.overlay) |overlay| {
        sampleClip(skeleton.nodes, model.clips[overlay.active], overlay.current_time, model.overlay_mask);
    }
    if (skeleton.fade_time > 0) {
        skeleton.fade_time -= world.delta_time;
        const alpha = @max(skeleton.fade_time, 0) / AnimationInstance.fade_duration;
        for (skeleton.nodes, skeleton.fade_joints) |*node, fade_joint| {
            node.translation = std.math.lerp(node.translation, fade_joint.translation, @as(nz.Vec3(f32), @splat(alpha)));
            node.rotation = nz.Quat(f32).slerp(node.rotation, fade_joint.rotation, alpha);
            node.scale = std.math.lerp(node.scale, fade_joint.scale, @as(nz.Vec3(f32), @splat(alpha)));
        }
    }
    var saved_look_rotations: [3]nz.Quat(f32) = undefined;
    const looking = entity.id == world.player_id and model.look_nodes.len > 0;
    if (looking) {
        for (model.look_nodes, 0..) |node_index, saved_index| {
            saved_look_rotations[saved_index] = skeleton.nodes[node_index].rotation;
        }
        const camera = &world.camera;
        const look_pitch = std.math.clamp(camera.pitch * look_pitch_sign, -1.0, 1.0);
        var yaw_offset = entity.transform.rotation.conjugate().mul(camera.yaw_rotation);
        if (yaw_offset.w < 0) yaw_offset = .{ .w = -yaw_offset.w, .x = -yaw_offset.x, .y = -yaw_offset.y, .z = -yaw_offset.z };
        var look_yaw = std.math.clamp(2 * std.math.atan2(yaw_offset.y, yaw_offset.w) * look_yaw_sign, -1.2, 1.2);
        if (@abs(look_yaw) < look_yaw_deadzone) look_yaw = 0;
        const aim_nodes: []const usize = if (skeleton.overlay != null) model.look_nodes[0..1] else model.look_nodes;
        const pitch_per_node = look_pitch / @as(f32, @floatFromInt(aim_nodes.len));
        const yaw_per_node = look_yaw / @as(f32, @floatFromInt(aim_nodes.len));
        for (aim_nodes) |node_index| {
            const node = &skeleton.nodes[node_index];
            node.rotation = node.rotation
                .mul(nz.Quat(f32).angleAxis(pitch_per_node, .{ 1, 0, 0 }))
                .mul(nz.Quat(f32).angleAxis(yaw_per_node, .{ 0, 1, 0 }))
                .normalize();
        }
    }
    Model.computeMatrices(skeleton.nodes);
    if (looking) {
        for (model.look_nodes, 0..) |node_index, saved_index| {
            skeleton.nodes[node_index].rotation = saved_look_rotations[saved_index];
        }
    }
    for (model.skins, skeleton.joint_matrices) |skin, joint_matrices| {
        for (skin.joints, skin.inverse_bind_matrices.?, joint_matrices) |node_index, inverse_bind_matrix, *joint_matrix| {
            joint_matrix.* = skeleton.nodes[node_index].model_matrix.mul(inverse_bind_matrix);
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
