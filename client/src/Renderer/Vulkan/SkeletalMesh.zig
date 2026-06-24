const std = @import("std");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Node = @import("Node.zig");
const Skin = @import("Skin.zig");
const Mesh = @import("Mesh.zig");
const AnimationClip = @import("AnimationClip.zig");
const RenderResources = @import("RenderResources.zig");
const AssetServer = @import("shared").AssetServer;
const gltf = @import("gltf.zig");

device: Device,
vma: Vma,
model_name: []const u8,
render_resources: *RenderResources,
nodes: std.ArrayList(Node) = .empty,
top_nodes: std.ArrayList(usize) = .empty,
clips: std.ArrayList(AnimationClip) = .empty,
skins: std.ArrayList(Skin) = .empty,
offset: nz.Transform3D(f32) = .{},
has_loaded: bool = false,

pub fn load(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    asset_server: *AssetServer,
    render_resources: *RenderResources,
    path: []const u8,
    offset: nz.Transform3D(f32),
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .model_name = try gpa.dupe(u8, path),
        .render_resources = render_resources,
        .nodes = .empty,
        .top_nodes = .empty,
        .clips = .empty,
        .skins = .empty,
        .offset = offset,
    };
    try asset_server.loadAsset(@This(), self, path, loadAsset);
    return self;
}

fn loadAsset(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;

    const self: *@This() = @ptrCast(@alignCast(user_data));

    if (self.has_loaded) {
        self.clear(gpa);
    } else {
        self.has_loaded = true;
    }

    var glb = try gltf.readGlb(gpa, io, file);
    defer glb.deinit(gpa);
    const gltf_loaded = glb.gltf;
    const bin = glb.bin;

    try gltf.parseScene(Mesh.SkinnedVertex, gpa, self.vma, self.device, self.render_resources, gltf_loaded, bin, &self.nodes, &self.top_nodes);

    if (gltf_loaded.skins) |skins| {
        const model_skins = try self.skins.addManyAsSlice(gpa, skins.len);
        for (skins, model_skins) |skin, *model_skin| {
            const joints = try gpa.alloc(usize, skin.joints.len);
            for (skin.joints, 0..) |node_index, joint_index| {
                joints[joint_index] = node_index;
            }
            var matrices: ?[]nz.Mat4x4(f32) = null;
            if (skin.inverseBindMatrices.? > -1) {
                const accessor = gltf_loaded.accessors.?[skin.inverseBindMatrices.?];
                const mat_buffer_view = gltf_loaded.bufferViews.?[@intCast(accessor.bufferView.?)];
                const matrix_data = bin[accessor.byteOffset + mat_buffer_view.byteOffset .. accessor.byteOffset + mat_buffer_view.byteOffset + mat_buffer_view.byteLength];
                matrices = try gpa.alloc(nz.Mat4x4(f32), accessor.count);
                @memcpy(std.mem.sliceAsBytes(matrices.?), matrix_data);
            }
            model_skin.* = try .init(
                gpa,
                skin.name orelse "skin",
                matrices,
                joints,
            );
        }
    }

    if (gltf_loaded.animations) |animations| {
        const model_animations = try self.clips.addManyAsSlice(gpa, animations.len);
        for (animations, model_animations) |gltf_animation, *model_animation| {
            model_animation.* = try .init(
                gpa,
                gltf_animation.name orelse "animation",
                gltf_animation.samplers.len,
                gltf_animation.channels.len,
            );
            for (gltf_animation.samplers) |sampler| {
                const in_sampler_accessor = gltf_loaded.accessors.?[sampler.input];
                const out_sampler_accessor = gltf_loaded.accessors.?[sampler.output];

                const model_sampler = model_animation.samplers.addOneAssumeCapacity();
                model_sampler.* = try .init(gpa, sampler.interpolation, in_sampler_accessor.count, out_sampler_accessor.count);

                const in_sampler_buffer_view = gltf_loaded.bufferViews.?[@intCast(in_sampler_accessor.bufferView.?)];
                const in_sampler_offset = in_sampler_accessor.byteOffset + in_sampler_buffer_view.byteOffset;
                const in_sampler_data = bin[in_sampler_offset .. in_sampler_offset + in_sampler_buffer_view.byteLength];
                for (0..in_sampler_accessor.count) |i| {
                    const value: f32 = @bitCast(in_sampler_data[i * 4 ..][0..4].*);
                    model_sampler.inputs.appendAssumeCapacity(value);
                }
                for (model_sampler.inputs.items) |input| {
                    if (input < model_animation.start) model_animation.start = input;
                    if (input > model_animation.end) model_animation.end = input;
                }

                const out_sampler_buffer_view = gltf_loaded.bufferViews.?[@intCast(out_sampler_accessor.bufferView.?)];
                const offset = out_sampler_accessor.byteOffset + out_sampler_buffer_view.byteOffset;
                const out_sampler_data = bin[offset .. offset + out_sampler_buffer_view.byteLength];
                switch (out_sampler_accessor.type) {
                    .VEC3 => {
                        for (0..out_sampler_accessor.count) |i| {
                            const value: [3]f32 = @bitCast(out_sampler_data[i * 12 ..][0..12].*);
                            model_sampler.outputs.appendAssumeCapacity(.{ value[0], value[1], value[2], 0 });
                        }
                    },
                    .VEC4 => {
                        for (0..out_sampler_accessor.count) |i| {
                            const value: [4]f32 = @bitCast(out_sampler_data[i * 16 ..][0..16].*);
                            model_sampler.outputs.appendAssumeCapacity(value);
                        }
                    },
                    else => {},
                }
            }
            for (gltf_animation.channels) |channel| {
                const model_channel = model_animation.channels.addOneAssumeCapacity();
                model_channel.* = .{
                    .path = channel.target.coreKind() orelse return error.AnimationTargetPath,
                    .node = if (channel.target.node) |node_index| node_index else null,
                    .sampler_index = channel.sampler,
                };
            }
        }
    }
}

pub fn clear(self: *@This(), gpa: std.mem.Allocator) void {
    for (self.nodes.items) |*node| node.deinit(gpa);
    self.nodes.clearAndFree(gpa);
    for (self.clips.items) |*clip| clip.deinit(gpa);
    self.clips.clearAndFree(gpa);
    for (self.skins.items) |*skin| skin.deinit(gpa);
    self.skins.clearAndFree(gpa);
    self.top_nodes.clearAndFree(gpa);
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.clear(gpa);
    self.nodes.deinit(gpa);
    self.clips.deinit(gpa);
    self.skins.deinit(gpa);
    self.top_nodes.deinit(gpa);
    gpa.free(self.model_name);
    self.* = undefined;
    gpa.destroy(self);
}
