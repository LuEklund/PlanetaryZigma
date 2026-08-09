const Animator = @This();

const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const Model = @import("assets").Model;
const Node = @import("assets").Node;
const AnimationClip = @import("assets").AnimationClip;
const Instance = @import("Animator/Instance.zig");
const ModelTable = @import("assets").ModelTable;
const DrawList = @import("render").DrawList;
const Emitter = @import("shared").Emitter;
const Shader = @import("shared").Shader;

const max_skins = 8;

const look_pitch_sign: f32 = -1;
const look_yaw_sign: f32 = 1;
const look_yaw_deadzone: f32 = 0.05;

pub const item_spin_speed: f32 = 1.5;

fn easeOutBack(x: f32) f32 {
    const c1: f32 = 1.70158;
    const c3: f32 = c1 + 1.0;
    const xm1 = x - 1.0;
    return 1.0 + c3 * xm1 * xm1 * xm1 + c1 * xm1 * xm1;
}

pub const Frame = struct {
    delta_time: f32,
    elapsed_time: f32,
    local_entity: shared.entity.Id,
    camera_pitch: f32,
    camera_yaw_rotation: nz.Quat(f32),
};

/// One entity as the animator sees it — deliberately wire-shaped, so a server-side
/// producer fills it from the sim and a client one from replicated state.
pub const Entity = struct {
    id: shared.entity.Id,
    /// Which model, decided by the caller. The animator never maps a game kind to an asset.
    model: Model.Handle,
    transform: nz.Transform3D(f32),
    /// Applied after `transform`; comes from the caller's model spec.
    offset: nz.Transform3D(f32),
    is_dying: bool,
    /// Which clip to play. Derived by the caller (shared.entity.animationState).
    state: shared.entity.State,
    /// Presentation, decided by the caller — these used to be `switch (kind)` arms here.
    highlight: bool,
    spin_speed: f32,
    shrink_on_death: bool,
    effect: ?Shader.Kind,
};

gpa: std.mem.Allocator,
instances: std.AutoHashMap(shared.entity.Id, Instance),
retiring: std.ArrayList(shared.entity.Id),
frame: Frame,

pub fn init(gpa: std.mem.Allocator) !Animator {
    return .{
        .gpa = gpa,
        .instances = .init(gpa),
        .retiring = try .initCapacity(gpa, shared.max_entities * 2),
        .frame = .{ .delta_time = 0, .elapsed_time = 0, .local_entity = .none, .camera_pitch = 0, .camera_yaw_rotation = .identity },
    };
}

pub fn deinit(self: *Animator) void {
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.deinit(self.gpa);
    self.instances.deinit();
    self.retiring.deinit(self.gpa);
}

fn resolveModel(models: *ModelTable, instance: *const Instance) ?*Model {
    return models.modelPtr(instance.model);
}

pub fn begin(self: *Animator, frame: Frame, deaths: []const shared.entity.Id, models: *ModelTable) !void {
    self.frame = frame;
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.seen = false;
    for (deaths) |id| {
        const instance = self.instances.getPtr(id) orelse continue;
        instance.is_dying = true;
        instance.state = .death;
    }
    try self.applyReloads(models);
}

pub fn observe(self: *Animator, entity: Entity, models: *ModelTable) !void {
    if (!self.instances.contains(entity.id)) {
        const model = models.modelPtr(entity.model);
        if (model) |file_model| if (file_model.isEmpty()) {
            std.log.err("model not loaded for entity {d}", .{entity.id});
        };
        try self.instances.put(entity.id, try .init(self.gpa, entity.model, model));
    }
    const instance = self.instances.getPtr(entity.id).?;
    instance.seen = true;
    instance.model = entity.model;
    instance.offset = entity.offset;
    instance.highlight = entity.highlight;
    instance.spin_speed = entity.spin_speed;
    instance.shrink_on_death = entity.shrink_on_death;
    instance.effect = entity.effect;
    instance.transform = entity.transform;
    instance.is_dying = entity.is_dying;
    if (instance.skeleton == null) return;
    instance.state = entity.state;
}

pub fn advance(self: *Animator, triggers: []const shared.net.Event.Trigger, models: *ModelTable) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.applyTriggers(triggers, models);
    self.animate(models);
}

pub fn draw(self: *Animator, list: *DrawList, emitters: *Emitter.List, models: *const ModelTable) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.appendDraws(list, emitters, models);
    self.retire();
}

fn applyReloads(self: *Animator, models: *ModelTable) !void {
    for (models.reloaded.items) |file_index| {
        const reloaded_model = &models.models[file_index];
        var instance_iterator = self.instances.valueIterator();
        while (instance_iterator.next()) |instance| {
            const handle = instance.model;
            if (handle != .file or handle.file != file_index) continue;
            if (instance.skeleton) |*skeleton| skeleton.deinit(self.gpa);
            instance.skeleton = if (reloaded_model.isSkinned()) try .init(self.gpa, reloaded_model) else null;
            instance.spawn_duration = reloaded_model.spawn_duration;
            instance.death_duration = reloaded_model.death_duration;
        }
    }
    models.reloaded.clearRetainingCapacity();
}

pub fn clear(self: *Animator) void {
    var instance_iterator = self.instances.valueIterator();
    while (instance_iterator.next()) |instance| instance.deinit(self.gpa);
    self.instances.clearRetainingCapacity();
}

fn retire(self: *Animator) void {
    self.retiring.clearRetainingCapacity();
    var instance_iterator = self.instances.iterator();
    while (instance_iterator.next()) |entry| {
        const instance = entry.value_ptr;
        if (instance.seen) continue;
        if (instance.is_dying and instance.death_time < instance.death_duration) continue;
        self.retiring.appendAssumeCapacity(entry.key_ptr.*);
    }
    for (self.retiring.items) |id| {
        var instance = self.instances.fetchRemove(id).?.value;
        instance.deinit(self.gpa);
    }
}

fn applyTriggers(self: *Animator, triggers: []const shared.net.Event.Trigger, models: *ModelTable) void {
    for (triggers) |trigger| {
        const instance = self.instances.getPtr(trigger.id) orelse continue;
        const skeleton = if (instance.skeleton) |*skeleton| skeleton else continue;
        const model = resolveModel(models, instance) orelse continue;
        const clip_index = model.state_clips.get(trigger.state) orelse continue;
        skeleton.playOverlay(model, clip_index);
    }
}

fn animate(self: *Animator, models: *ModelTable) void {
    var instance_iterator = self.instances.iterator();
    while (instance_iterator.next()) |entry| {
        const instance = entry.value_ptr;
        if (instance.is_dying) {
            instance.death_time += self.frame.delta_time;
        } else if (instance.death_time > 0) {
            instance.death_time = 0;
        }
        if (instance.spin_speed != 0) {
            instance.spawn_time = @min(instance.spawn_time + self.frame.delta_time, instance.spawn_duration);
            instance.spin_time += self.frame.delta_time;
        }
        const model = resolveModel(models, instance) orelse continue;
        playAnimation(self.frame, entry.key_ptr.*, instance, model);
    }
}

fn appendDraws(self: *Animator, list: *DrawList, emitters: *Emitter.List, models: *const ModelTable) void {
    var instance_iterator = self.instances.iterator();
    while (instance_iterator.next()) |entry| {
        const instance = entry.value_ptr;
        if (instance.effect) |effect| {
            const effect_offset = nz.vec.scale(nz.vec.normalize(instance.transform.position), 0.5);
            Emitter.keepAlive(emitters, effect, entry.key_ptr.*, instance.transform.position - effect_offset, self.frame.elapsed_time);
        }
        var transform = instance.transform;
        if (instance.shrink_on_death and instance.is_dying and instance.death_duration > 0) {
            transform.scale = @splat(1.0 - std.math.clamp(instance.death_time / instance.death_duration, 0, 1));
        }
        if (instance.spin_speed != 0) {
            if (instance.spawn_duration > 0) {
                transform.scale = @splat(0.1 + 0.9 * easeOutBack(std.math.clamp(instance.spawn_time / instance.spawn_duration, 0, 1)));
            }
            transform.rotation = transform.rotation
                .mul(nz.Quat(f32).angleAxis(instance.spin_speed * instance.spin_time, .{ 0, 1, 0 }))
                .normalize();
        }
        const top_matrix = transform.toMat4x4().mul(instance.offset.toMat4x4());
        if (instance.skeleton) |*instance_skeleton| {
            var skin_offsets: [max_skins]u32 = undefined;
            const palette_base: u32 = @intCast(list.joint_matrices.items.len);
            list.joint_matrices.appendSliceAssumeCapacity(instance_skeleton.joints);
            for (0..instance_skeleton.skin_starts.len - 1) |skin_index| {
                skin_offsets[skin_index] = palette_base + instance_skeleton.skin_starts[skin_index];
            }
            const file_index = switch (instance.model) {
                .file => |index| index,
                .generated => continue,
            };
            const mesh_handles = models.models[file_index].mesh_handles;
            for (instance_skeleton.nodes) |node| {
                const mesh_id = node.mesh_id orelse continue;
                if (mesh_id >= mesh_handles.len) continue;
                list.draw_meshes.appendAssumeCapacity(.{
                    .mesh = @enumFromInt(mesh_handles[mesh_id]),
                    .model_matrix = if (node.skin_id != null) top_matrix else top_matrix.mul(node.model_matrix),
                    .position = instance.transform.position,
                    .palette_offset = if (node.skin_id) |skin_index| skin_offsets[skin_index] else null,
                    .skinned = true,
                    .highlight = instance.highlight,
                });
            }
        } else switch (instance.model) {
            .generated => |generated| list.draw_meshes.appendAssumeCapacity(.{
                .mesh = @enumFromInt(models.generated[@intFromEnum(generated)]),
                .model_matrix = top_matrix,
                .position = instance.transform.position,
                .palette_offset = null,
                .skinned = false,
                .highlight = instance.highlight,
            }),
            // The surface walk lives here now: one row per surface, so the backend never
            // expands one row into many draws and the rows stay sortable.
            .file => |file_index| {
                const model = &models.models[file_index];
                if (model.isEmpty() or model.isSkinned()) continue;
                for (model.surfaces.items) |surface| {
                    if (surface.mesh_id >= model.mesh_handles.len) continue;
                    list.draw_meshes.appendAssumeCapacity(.{
                        .mesh = @enumFromInt(model.mesh_handles[surface.mesh_id]),
                        .model_matrix = top_matrix.mul(surface.model_matrix),
                        .position = instance.transform.position,
                        .palette_offset = null,
                        .skinned = false,
                        .highlight = instance.highlight,
                    });
                }
            },
        }
    }
}

fn playAnimation(frame: Frame, id: shared.entity.Id, instance: *Instance, model: *Model) void {
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
        const alpha = @max(skeleton.fade_time, 0) / Instance.fade_duration;
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
