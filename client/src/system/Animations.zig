const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;
const SkeletalMesh = @import("../Renderer/Vulkan/SkeletalMesh.zig");
const Renderer = @import("../Renderer/Vulkan.zig");
const Node = @import("../Renderer/Vulkan/Node.zig");
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
        const skeleton_animation = skeletons.getPtr(entity.id) orelse continue;
        const model = skeleton_animation.model;
        if (model.clips.items.len == 0) continue;
        const animation = model.clips.items[skeleton_animation.player.active];
        skeleton_animation.player.current_time += info.delta_time;

        if (skeleton_animation.player.current_time > animation.end) {
            if (skeleton_animation.player.loop) skeleton_animation.player.current_time -= animation.end else {
                skeleton_animation.player.active = skeleton_animation.player.default;
                skeleton_animation.player.current_time = 0;
            }
        }
        for (animation.channels.items) |*channel| {
            const sampler = animation.samplers.items[channel.sampler_index];
            for (0..sampler.inputs.items.len - 1) |i| {
                const sampler_in = sampler.inputs.items[i];
                const sampler_in_next = sampler.inputs.items[i + 1];
                if (skeleton_animation.player.current_time >= sampler_in and skeleton_animation.player.current_time <= sampler_in_next) {
                    const interpolate_value: f32 = (skeleton_animation.player.current_time - sampler_in) / (sampler_in_next - sampler_in);
                    const node_id = channel.node orelse return error.NoNode;
                    const node = &skeleton_animation.nodes[node_id];
                    const sampler_out = sampler.outputs.items[i];
                    const sampler_out_next = sampler.outputs.items[i + 1];
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
                        .weights => {
                            return error.WeightsNotImplemented;
                        },
                    }
                }
            }
        }
        for (model.top_nodes.items) |node_index| {
            var top_matrix: nz.Mat4x4(f32) = .identity;
            skeleton_animation.nodes[node_index].refreshMatrices(skeleton_animation.nodes, &top_matrix);
        }
        for (model.top_nodes.items) |root_index| {
            updateJoints(root_index, skeleton_animation, model);
        }
    }
}

fn updateJoints(node_index: usize, skeleton_animation: *SkeletonInstance, model: *SkeletalMesh) void {
    const node = &skeleton_animation.nodes[node_index];
    if (node.skin_id > -1) {
        const skin = &model.skins.items[@intCast(node.skin_id)];
        const inverse_bind_matrices = skin.inverse_bind_matrices.?;
        const inverse_transform: nz.Mat4x4(f32) = node.world_matrix.inverse();
        const joint_matrices: [*]nz.Mat4x4(f32) = @ptrCast(@alignCast(skeleton_animation.buffers[@intCast(node.skin_id)].info.pMappedData));
        for (skin.joints, 0..) |joint_idnex, i| {
            joint_matrices[i] = inverse_transform.mul(skeleton_animation.nodes[joint_idnex].world_matrix.mul(inverse_bind_matrices.items[i]));
        }
    }
    for (node.children.items) |child_id| {
        // std.log.debug("Update Child", .{node.translation});
        updateJoints(child_id, skeleton_animation, model);
    }
}
