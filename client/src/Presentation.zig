const Presentation = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const View = @import("View.zig");
const Model = @import("asset/Model.zig");
const Node = @import("asset/Node.zig");
const AnimationClip = @import("asset/AnimationClip.zig");
const AnimationInstance = @import("asset/AnimationInstance.zig");
const ModelLoader = @import("Renderer/loader/ModelLoader.zig");
const FramePacket = @import("Renderer/FramePacket.zig");

const max_skins = 8;

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
instances: std.AutoHashMap(shared.entity.Id, AnimationInstance),
retiring: std.ArrayList(shared.entity.Id),
frame: View.Frame,

pub fn init(gpa: std.mem.Allocator) !Presentation {
    return .{
        .gpa = gpa,
        .instances = .init(gpa),
        .retiring = try .initCapacity(gpa, shared.max_entities),
        .frame = .{ .delta_time = 0, .local_entity = .none, .camera_pitch = 0, .camera_yaw_rotation = .identity },
    };
}

pub fn deinit(self: *Presentation) void {
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.deinit(self.gpa);
    self.instances.deinit();
    self.retiring.deinit(self.gpa);
}

fn resolveModel(loader: *ModelLoader, instance: *const AnimationInstance) ?*Model {
    return loader.modelPtr(instance.model_handle orelse return null);
}

pub fn begin(self: *Presentation, frame: View.Frame, deaths: []const shared.entity.Id, loader: *ModelLoader) !void {
    self.frame = frame;
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.seen = false;
    for (deaths) |id| {
        const instance = self.instances.getPtr(id) orelse continue;
        instance.is_dying = true;
        instance.state = .death;
    }
    try self.applyReloads(loader);
}

pub fn observe(self: *Presentation, entity: View.Entity, loader: *ModelLoader) !void {
    if (shared.entity.modelSpec(entity.kind) == null) return;
    if (!self.instances.contains(entity.id)) {
        const handle = loader.handleForKind(entity.kind);
        const model = if (handle) |model_handle| loader.modelPtr(model_handle) else null;
        if (model) |file_model| if (file_model.isEmpty()) {
            std.log.err("model not loaded for {s}", .{@tagName(entity.kind)});
        };
        try self.instances.put(entity.id, try .init(self.gpa, entity.kind, handle, model));
    }
    const instance = self.instances.getPtr(entity.id).?;
    instance.seen = true;
    instance.kind = entity.kind;
    instance.transform = entity.transform;
    instance.is_dying = entity.is_dying;
    if (instance.skeleton == null) return;

    var state: shared.entity.State = if (nz.vec.length(entity.velocity) > 0.5) .walk else .idle;
    state = if (entity.stun_time > 0) .stun else state;
    state = if (entity.is_dying) .death else state;
    if (entity.state_override) |override| state = override;
    instance.state = state;
}

pub fn finish(self: *Presentation, triggers: []const shared.net.Event.Trigger, loader: *ModelLoader, packet: *FramePacket) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.applyTriggers(triggers, loader);
    self.animate(loader);
    self.appendDraws(packet);
    self.retire();
}

fn applyReloads(self: *Presentation, loader: *ModelLoader) !void {
    for (loader.reloaded.items) |file_index| {
        const reloaded_model = &loader.entries[file_index].model;
        var instance_iterator = self.instances.valueIterator();
        while (instance_iterator.next()) |instance| {
            const handle = instance.model_handle orelse continue;
            if (handle != .file or handle.file != file_index) continue;
            if (instance.skeleton) |*skeleton| skeleton.deinit(self.gpa);
            instance.skeleton = if (reloaded_model.isSkinned()) try .init(self.gpa, reloaded_model) else null;
        }
    }
    loader.reloaded.clearRetainingCapacity();
}

pub fn clear(self: *Presentation) void {
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.deinit(self.gpa);
    self.instances.clearRetainingCapacity();
}

fn retire(self: *Presentation) void {
    self.retiring.clearRetainingCapacity();
    var instance_iterator = self.instances.iterator();
    while (instance_iterator.next()) |entry| {
        const instance = entry.value_ptr;
        if (instance.seen) continue;
        if (instance.is_dying and !instance.deathDone()) continue;
        self.retiring.appendAssumeCapacity(entry.key_ptr.*);
    }
    for (self.retiring.items) |id| {
        var instance = self.instances.fetchRemove(id).?.value;
        instance.deinit(self.gpa);
    }
}

fn applyTriggers(self: *Presentation, triggers: []const shared.net.Event.Trigger, loader: *ModelLoader) void {
    for (triggers) |trigger| {
        const instance = self.instances.getPtr(trigger.id) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        const model = resolveModel(loader, instance) orelse continue;
        const clip_index = model.state_clips.get(trigger.state) orelse continue;
        skeleton.playOverlay(model, clip_index);
    }
}

fn animate(self: *Presentation, loader: *ModelLoader) void {
    var instance_iterator = self.instances.iterator();
    while (instance_iterator.next()) |entry| {
        const instance = entry.value_ptr;
        if (instance.is_dying) {
            instance.death_time += self.frame.delta_time;
        } else if (instance.death_time > 0) {
            instance.death_time = 0;
        }
        if (instance.kind == .item) {
            instance.spawn_time = @min(instance.spawn_time + self.frame.delta_time, instance.spawnDuration());
            instance.spin_time += self.frame.delta_time;
        }
        const model = resolveModel(loader, instance) orelse continue;
        playAnimation(self.frame, entry.key_ptr.*, instance, model);
    }
}

fn appendDraws(self: *Presentation, packet: *FramePacket) void {
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| {
        const model_spec = shared.entity.modelSpec(instance.kind) orelse continue;
        var transform = instance.transform;
        switch (instance.kind) {
            .lootbox => {
                if (instance.is_dying and instance.deathDuration() > 0) {
                    transform.scale = @splat(1.0 - std.math.clamp(instance.death_time / instance.deathDuration(), 0, 1));
                }
            },
            .item => {
                if (instance.spawnDuration() > 0) {
                    transform.scale = @splat(0.1 + 0.9 * easeOutBack(std.math.clamp(instance.spawn_time / instance.spawnDuration(), 0, 1)));
                }
                transform.rotation = transform.rotation
                    .mul(nz.Quat(f32).angleAxis(item_spin_speed * instance.spin_time, .{ 0, 1, 0 }))
                    .normalize();
            },
            else => {},
        }
        const top_matrix = transform.toMat4x4().mul(model_spec.offset.toMat4x4());
        if (instance.skeleton) |*instance_skeleton| {
            var skin_offsets: [max_skins]u32 = undefined;
            for (instance_skeleton.joint_matrices, 0..) |matrices, skin_index| {
                skin_offsets[skin_index] = @intCast(packet.joint_matrices.items.len);
                packet.joint_matrices.appendSliceAssumeCapacity(matrices);
            }
            for (instance_skeleton.nodes) |node| {
                const mesh_id = node.mesh_id orelse continue;
                packet.draw_models.appendAssumeCapacity(.{
                    .kind = instance.kind,
                    .model_matrix = if (node.skin_id != null) top_matrix else top_matrix.mul(node.model_matrix),
                    .position = instance.transform.position,
                    .mesh_id = @intCast(mesh_id),
                    .palette_offset = if (node.skin_id) |skin_index| skin_offsets[skin_index] else null,
                });
            }
        } else {
            packet.draw_models.appendAssumeCapacity(.{
                .kind = instance.kind,
                .model_matrix = top_matrix,
                .position = instance.transform.position,
                .mesh_id = null,
                .palette_offset = null,
            });
        }
    }
}

fn playAnimation(frame: View.Frame, id: shared.entity.Id, instance: *AnimationInstance, model: *Model) void {
    const skeleton = if (instance.skeleton) |*instance_skeleton| instance_skeleton else return;
    const clip_index = model.state_clips.get(instance.state);
    if (clip_index) |index| {
        if (index != skeleton.player.active) {
            skeleton.playClip(model, index);
        }
    }

    if (skeleton.overlay) |*overlay| {
        overlay.current_time += frame.delta_time;
        if (overlay.current_time > model.clips[overlay.active].end) {
            skeleton.overlay = null;
            skeleton.startFade();
        }
    }

    if (clip_index != null) {
        const animation = model.clips[skeleton.player.active];
        skeleton.player.current_time += frame.delta_time;

        if (skeleton.player.current_time > animation.end) {
            if (instance.is_dying)
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
        skeleton.fade_time -= frame.delta_time;
        const alpha = @max(skeleton.fade_time, 0) / AnimationInstance.fade_duration;
        for (skeleton.nodes, skeleton.fade_joints) |*node, fade_joint| {
            node.translation = std.math.lerp(node.translation, fade_joint.translation, @as(nz.Vec3(f32), @splat(alpha)));
            node.rotation = nz.Quat(f32).slerp(node.rotation, fade_joint.rotation, alpha);
            node.scale = std.math.lerp(node.scale, fade_joint.scale, @as(nz.Vec3(f32), @splat(alpha)));
        }
    }
    var saved_look_rotations: [3]nz.Quat(f32) = undefined;
    const looking = id == frame.local_entity and model.look_nodes.len > 0;
    if (looking) {
        for (model.look_nodes, 0..) |node_index, saved_index| {
            saved_look_rotations[saved_index] = skeleton.nodes[node_index].rotation;
        }
        const look_pitch = std.math.clamp(frame.camera_pitch * look_pitch_sign, -1.0, 1.0);
        var yaw_offset = instance.transform.rotation.conjugate().mul(frame.camera_yaw_rotation);
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
