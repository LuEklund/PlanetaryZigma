const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;
const Renderer = @import("../Renderer/Vulkan.zig");
const Model = @import("../Renderer/Vulkan/Model.zig");
const SkeletonInstance = @import("../Renderer/Vulkan/SkeletonInstance.zig");

gpa: std.mem.Allocator,

pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
    self.* = .{ .gpa = gpa };
}

pub fn update(
    self: *@This(),
    info: *const Info,
    skeletons: *std.AutoHashMap(u32, SkeletonInstance),
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    // std.log.debug("render ptr {*}, model ptr{*}", .{ self.renderer, models });
    for (info.world.entities.values()) |*entity| {
        const instance = skeletons.getPtr(entity.id) orelse continue;
        const model = instance.model;
        if (model.clips.len == 0) continue;

        const oneshot_playing = !instance.player.loop and
            instance.player.current_time <= model.clips[instance.player.active].end;
        if (!oneshot_playing) {
            const speed = if (entity.update_motion) |update_motion| nz.vec.length(update_motion.velocity) else 0;
            const state: shared.Entity.State = if (speed > 0.5) .walk else .idle;
            const state_clip = model.state_clips.get(state);
            if (state_clip.index != instance.player.active) {
                instance.player.active = state_clip.index;
                instance.player.current_time = model.clips[state_clip.index].start;
            }
            instance.player.loop = state_clip.loop;
        }

        const animation = model.clips[instance.player.active];
        instance.player.current_time += info.delta_time;

        if (instance.player.loop and instance.player.current_time > animation.end) {
            instance.player.current_time -= animation.end - animation.start;
        }
        for (animation.channels) |*channel| {
            const sampler = animation.samplers[channel.sampler_index];
            for (0..sampler.inputs.len - 1) |i| {
                const sampler_in = sampler.inputs[i];
                const sampler_in_next = sampler.inputs[i + 1];
                if (instance.player.current_time >= sampler_in and instance.player.current_time <= sampler_in_next) {
                    const interpolate_value: f32 = (instance.player.current_time - sampler_in) / (sampler_in_next - sampler_in);
                    const node = &instance.nodes[channel.node];
                    const sampler_out = sampler.outputs[i];
                    const sampler_out_next = sampler.outputs[i + 1];
                    switch (channel.path) {
                        .translation => {
                            const new_val = std.math.lerp(
                                sampler_out,
                                sampler_out_next,
                                @as(nz.Vec4(f32), @splat(interpolate_value)),
                            );
                            node.translation = .{ new_val[0], new_val[1], new_val[2] };
                        },
                        .rotation => {
                            node.rotation = nz.Quat(f32).slerp(
                                .{ .w = sampler_out[3], .x = sampler_out[0], .y = sampler_out[1], .z = sampler_out[2] },
                                .{ .w = sampler_out_next[3], .x = sampler_out_next[0], .y = sampler_out_next[1], .z = sampler_out_next[2] },
                                interpolate_value,
                            );
                        },
                        .scale => {
                            const new_val = std.math.lerp(
                                sampler_out,
                                sampler_out_next,
                                @as(nz.Vec4(f32), @splat(interpolate_value)),
                            );
                            node.scale = .{ new_val[0], new_val[1], new_val[2] };
                        },
                    }
                }
            }
        }
        Model.computeMatrices(instance.nodes);
        for (instance.nodes) |*node| {
            const skin_index = node.skin_id orelse continue;
            const skin = model.skins[skin_index];
            const palette = instance.palettes[skin_index];
            const mesh_node_matrix_inverse = node.model_matrix.inverse();
            for (0..skin.joints.len) |joint_index| {
                const node_index = skin.joints[joint_index];
                const node_model_matrix = instance.nodes[node_index].model_matrix;
                const inverse_bind_matrix = skin.inverse_bind_matrices.?[joint_index];
                palette[joint_index] = mesh_node_matrix_inverse.mul(node_model_matrix.mul(inverse_bind_matrix));
            }
        }
    }
}
