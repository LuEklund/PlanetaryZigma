const Animator = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = @import("numz");
const Model = @import("assets/root.zig").Model;
const Node = @import("assets/root.zig").Node;
const AnimationClip = @import("assets/root.zig").AnimationClip;
const Instance = @import("Animator/Instance.zig");
const Rig = @import("Rig.zig");
const Models = @import("Models.zig");

pub const max_skins = 8;

pub const Handle = enum(u32) { none = 0, _ };

pub const Aim = Instance.Aim;

pub const item_spin_speed: f32 = 1.5;

pub const Pose = struct {
    model: u32,
    skeleton: ?*const Instance.Skeleton,
};

gpa: std.mem.Allocator,
instances: std.ArrayList(?Instance),
free_slots: std.ArrayList(u32),

pub fn init(gpa: std.mem.Allocator) !Animator {
    return .{
        .gpa = gpa,
        .instances = try .initCapacity(gpa, shared.max_entities * 2),
        .free_slots = try .initCapacity(gpa, shared.max_entities * 2),
    };
}

pub fn deinit(self: *Animator) void {
    for (self.instances.items) |*slot| {
        if (slot.*) |*instance| instance.deinit(self.gpa);
    }
    self.instances.deinit(self.gpa);
    self.free_slots.deinit(self.gpa);
}

pub fn create(self: *Animator, model_handle: u32, models: *const Models) !Handle {
    const instance: Instance = try .init(self.gpa, model_handle, models.modelPtr(model_handle));
    if (self.free_slots.pop()) |slot| {
        self.instances.items[slot] = instance;
        return @enumFromInt(slot + 1);
    }
    self.instances.appendAssumeCapacity(instance);
    return @enumFromInt(self.instances.items.len);
}

pub fn destroy(self: *Animator, handle: Handle) void {
    const slot = self.slotOf(handle) orelse return;
    if (self.instances.items[slot]) |*instance| instance.deinit(self.gpa);
    self.instances.items[slot] = null;
    self.free_slots.appendAssumeCapacity(@intCast(slot));
}

fn slotOf(self: *const Animator, handle: Handle) ?usize {
    const raw = @intFromEnum(handle);
    if (raw == 0 or raw > self.instances.items.len) return null;
    return raw - 1;
}

fn instancePtr(self: *Animator, handle: Handle) ?*Instance {
    const slot = self.slotOf(handle) orelse return null;
    return if (self.instances.items[slot]) |*instance| instance else null;
}

fn resolveModel(models: *const Models, instance: *const Instance) *const Model {
    return models.modelPtr(instance.model);
}

fn resolveRig(models: *const Models, instance: *const Instance) *const Rig {
    return models.rig(instance.model);
}

pub const LoopMode = Instance.LoopMode;

pub fn setLoop(self: *Animator, handle: Handle, clip: ?usize, mode: LoopMode) void {
    const instance = self.instancePtr(handle) orelse return;
    instance.loop_clip = clip;
    instance.loop_mode = mode;
}

pub fn setAim(self: *Animator, handle: Handle, aim: ?Instance.Aim) void {
    const instance = self.instancePtr(handle) orelse return;
    instance.aim = aim;
}

pub fn playOverlay(self: *Animator, handle: Handle, clip: usize, models: *const Models) void {
    const instance = self.instancePtr(handle) orelse return;
    const skeleton = if (instance.skeleton) |*instance_skeleton| instance_skeleton else return;
    skeleton.playOverlay(resolveModel(models, instance), clip);
}

pub fn advance(self: *Animator, delta_time: f32, models: *Models) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    try self.applyReloads(models);
    self.animate(delta_time, models);
}

fn applyReloads(self: *Animator, models: *Models) !void {
    for (models.reloaded.items) |file_index| {
        const reloaded_model = models.modelPtr(file_index);
        for (self.instances.items) |*slot| {
            const instance = if (slot.*) |*live| live else continue;
            if (instance.model != file_index) continue;
            if (instance.skeleton) |*skeleton| skeleton.deinit(self.gpa);
            instance.skeleton = if (reloaded_model.isSkinned()) try .init(self.gpa, reloaded_model) else null;
        }
    }
    models.reloaded.clearRetainingCapacity();
}

pub fn clear(self: *Animator) void {
    for (self.instances.items) |*slot| {
        if (slot.*) |*instance| instance.deinit(self.gpa);
    }
    self.instances.clearRetainingCapacity();
    self.free_slots.clearRetainingCapacity();
}

fn animate(self: *Animator, delta_time: f32, models: *Models) void {
    for (self.instances.items) |*slot| {
        const instance = if (slot.*) |*live| live else continue;
        playAnimation(delta_time, instance, resolveModel(models, instance), resolveRig(models, instance));
    }
}

pub fn pose(self: *Animator, handle: Handle) ?Pose {
    const instance = self.instancePtr(handle) orelse return null;
    return .{
        .model = instance.model,
        .skeleton = if (instance.skeleton) |*instance_skeleton| instance_skeleton else null,
    };
}

fn playAnimation(delta_time: f32, instance: *Instance, model: *const Model, rig: *const Rig) void {
    const skeleton = if (instance.skeleton) |*instance_skeleton| instance_skeleton else return;
    const clip_index = instance.loop_clip;
    if (clip_index) |index| {
        if (index != skeleton.player.active) {
            skeleton.playClip(model, index);
        }
    }

    if (skeleton.overlay) |*overlay| {
        overlay.current_time += delta_time;
        if (overlay.current_time > model.clips[overlay.active].end) {
            skeleton.overlay = null;
            skeleton.startFade();
        }
    }

    if (clip_index != null) {
        const animation = model.clips[skeleton.player.active];
        skeleton.player.current_time += delta_time;

        if (skeleton.player.current_time > animation.end) {
            if (instance.loop_mode == .hold_last)
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
        sampleClip(skeleton.nodes, model.clips[overlay.active], overlay.current_time, rig.overlay_mask);
    }
    if (skeleton.fade_time > 0) {
        skeleton.fade_time -= delta_time;
        const alpha = @max(skeleton.fade_time, 0) / Instance.fade_duration;
        for (skeleton.nodes, skeleton.fade_joints) |*node, fade_joint| {
            node.translation = std.math.lerp(node.translation, fade_joint.translation, @as(nz.Vec3(f32), @splat(alpha)));
            node.rotation = nz.Quat(f32).slerp(node.rotation, fade_joint.rotation, alpha);
            node.scale = std.math.lerp(node.scale, fade_joint.scale, @as(nz.Vec3(f32), @splat(alpha)));
        }
    }
    var saved_look_rotations: [3]nz.Quat(f32) = undefined;
    const looking = instance.aim != null and rig.look_nodes.len > 0;
    if (looking) {
        const aim = instance.aim.?;
        for (rig.look_nodes, 0..) |node_index, saved_index| {
            saved_look_rotations[saved_index] = skeleton.nodes[node_index].rotation;
        }
        const aim_nodes: []const usize = if (skeleton.overlay != null) rig.look_nodes[0..1] else rig.look_nodes;
        const pitch_per_node = aim.pitch / @as(f32, @floatFromInt(aim_nodes.len));
        const yaw_per_node = aim.yaw / @as(f32, @floatFromInt(aim_nodes.len));
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
        for (rig.look_nodes, 0..) |node_index, saved_index| {
            skeleton.nodes[node_index].rotation = saved_look_rotations[saved_index];
        }
    }
    for (model.skins, 0..) |skin, skin_index| {
        const joint_matrices = skeleton.joints[skeleton.skin_starts[skin_index]..skeleton.skin_starts[skin_index + 1]];
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
