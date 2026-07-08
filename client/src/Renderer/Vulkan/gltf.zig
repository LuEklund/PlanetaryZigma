const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const zgltf = @import("zgltf");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Image = @import("Image.zig");
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const Skin = @import("Skin.zig");
const AnimationClip = @import("AnimationClip.zig");
const Material = @import("Material.zig");
const Buffer = @import("Buffer.zig");
const Resources = @import("Resources.zig");
const check = @import("utils.zig").check;

pub const Glb = struct {
    content: []u8,
    loaded: zgltf.LoadedGlb,
    gltf: zgltf.Gltf,
    bin: []const u8,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.loaded.deinit();
        gpa.free(self.content);
    }
};

pub fn readGlb(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !Glb {
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(content);

    var loaded = try zgltf.parseGlbSlice(gpa, content);
    errdefer loaded.deinit();
    const bin = loaded.bin orelse return error.MissingBin;

    return .{ .content = content, .loaded = loaded, .gltf = loaded.parsed.value, .bin = bin };
}

pub fn parseScene(
    comptime VertexType: type,
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    resources: *Resources,
    gltf: zgltf.Gltf,
    bin: []const u8,
    out_nodes: *std.ArrayList(Node),
    out_skins: ?*[]Skin,
    out_clips: ?*[]AnimationClip,
    look_node_names: ?[]const []const u8,
    out_look_nodes: ?*[]usize,
) !void {
    const original_sample_count = resources.samplers.items.len;
    {
        if (gltf.samplers) |samplers| {
            std.log.info("Sampler count was {d}", .{samplers.len});
            for (samplers) |sampler| {
                const sampler_info: c.VkSamplerCreateInfo = .{
                    .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                    .maxLod = c.VK_LOD_CLAMP_NONE,
                    .minLod = 0,
                    .magFilter = if (sampler.magFilter) |filter| switch (filter) {
                        .nearest => c.VK_FILTER_NEAREST,
                        .linear => c.VK_FILTER_LINEAR,
                    } else c.VK_FILTER_LINEAR,
                    .minFilter = if (sampler.minFilter) |filter| switch (filter) {
                        .nearest => c.VK_FILTER_NEAREST,
                        .linear => c.VK_FILTER_LINEAR,
                        else => c.VK_FILTER_LINEAR,
                    } else c.VK_FILTER_LINEAR,
                    .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
                    .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                    .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                    .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                    .anisotropyEnable = c.VK_FALSE,
                    .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
                    .unnormalizedCoordinates = c.VK_FALSE,
                    .compareEnable = c.VK_FALSE,
                    .compareOp = c.VK_COMPARE_OP_ALWAYS,
                };
                var new_sampler: c.VkSampler = undefined;
                try check(c.vkCreateSampler(device.handle, &sampler_info, null, &new_sampler));
                try resources.samplers.append(gpa, new_sampler);
            }
        } else {
            std.log.info("Sampler count was 0", .{});
        }
    }

    const original_image_count = resources.images.items.len;
    {
        if (gltf.images) |images| {
            std.log.info("image count was {d}", .{images.len});
            var decoded_images = try gpa.alloc(Image.Decoded, images.len);
            defer {
                for (decoded_images) |*decoded_image| decoded_image.deinit();
                gpa.free(decoded_images);
            }
            @memset(decoded_images, .{});

            var decode_tasks = try gpa.alloc(Image.DecodeTask, images.len);

            defer {
                for (decode_tasks) |*task| {
                    if (task.uri) |uri| gpa.free(uri);
                }
                gpa.free(decode_tasks);
            }
            for (images, 0..) |image, image_index| {
                if (image.uri == null and image.bufferView == null) return error.FailedToLoadGLTFImage;

                decode_tasks[image_index] = .{ .result = &decoded_images[image_index] };
                if (image.uri) |uri| {
                    if (std.mem.startsWith(u8, uri, "data:")) return error.DataNotSupported;
                    decode_tasks[image_index].uri = try gpa.dupeSentinel(u8, uri, 0);
                } else if (image.bufferView) |buffer_view_index| {
                    const buffer_views = gltf.bufferViews orelse return error.MissingBufferViews;
                    const buffer_view = buffer_views[buffer_view_index];
                    const bytes_offset = buffer_view.byteOffset;
                    const byte_len = buffer_view.byteLength;
                    decode_tasks[image_index].bytes = bin[bytes_offset .. bytes_offset + byte_len];
                }
            }

            {
                try Image.decodeImages(gpa, decode_tasks);
            }

            var upload_buffers: std.ArrayList(Buffer) = .empty;
            defer {
                for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(vma);
                upload_buffers.deinit(gpa);
            }
            const upload_cmd = try device.beginImmediateCommand();
            for (decoded_images) |*decoded_image| {
                if (decoded_image.err) |err| return err;
                try if (decoded_image.pixels == null) error.LoadingStbi;
                var new_image: Image = try .init(
                    vma,
                    device,
                    c.VK_FORMAT_R8G8B8A8_UNORM,
                    .{ .width = @intCast(decoded_image.width), .height = @intCast(decoded_image.height), .depth = 1 },
                    .@"2d",
                    c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                    c.VK_IMAGE_ASPECT_COLOR_BIT,
                    true,
                );
                {
                    try new_image.recordUploadDataToImage(
                        gpa,
                        vma,
                        device,
                        upload_cmd,
                        decoded_image.pixels,
                        0,
                        4,
                        &upload_buffers,
                    );
                }
                decoded_image.deinit();
                try resources.images.append(gpa, new_image);
            }
            try device.endImmediateCommand(upload_cmd);
        } else {
            std.log.info("image count was 0", .{});
        }
    }

    const original_material_count = resources.materials.items.len;
    {
        if (gltf.materials) |materials| for (materials) |material| {
            var sampler = resources.samplers.items[0];
            var image_view = resources.images.items[0].vk_imageview;
            if (material.pbrMetallicRoughness) |metallic_roughness| {
                if (metallic_roughness.baseColorTexture) |base_texture| {
                    const texture_info = gltf.textures.?[base_texture.index];
                    if (texture_info.sampler) |sampler_index| sampler = resources.samplers.items[original_sample_count + sampler_index];
                    if (texture_info.source) |image_index| image_view = resources.images.items[original_image_count + image_index].vk_imageview;
                }
            }
            const new_material: Material = try .init(
                gpa,
                material.name orelse "material",
                device,
                vma,
                resources.set_size,
                resources.combined_image_sampler_descriptor_size,
                sampler,
                image_view,
            );
            try resources.materials.append(gpa, new_material);
        };
    }

    const original_mesh_count = resources.meshes.items.len;
    {
        if (gltf.meshes) |meshes| for (meshes) |mesh| {
            var surfaces: std.ArrayList(Mesh.GeoSurface) = try .initCapacity(gpa, mesh.primitives.len);
            defer surfaces.deinit(gpa);
            var vertices: std.ArrayList(VertexType) = .empty;
            defer vertices.deinit(gpa);
            var indices: std.ArrayList(u32) = .empty;
            defer indices.deinit(gpa);

            std.log.debug("MESH primitives: {d}\n", .{mesh.primitives.len});
            for (mesh.primitives) |primitive| {
                var indices_start: u32 = 0;
                var indices_count: u32 = 0;
                {
                    indices_start = @intCast(indices.items.len);

                    const acc_idx = primitive.indices.?;
                    var acc = gltf.accessors.?[acc_idx];
                    const bv = gltf.bufferViews.?[acc.bufferView.?];
                    const index_offset = bv.byteOffset + acc.byteOffset;

                    const element_size = try acc.elementSize();
                    const amount_of_bytes = acc.count * element_size;
                    const bytes = bin[index_offset .. index_offset + amount_of_bytes];

                    const dst = try indices.addManyAsSlice(gpa, acc.count);
                    for (0..acc.count) |i| {
                        const off = i * element_size;
                        dst[i] = switch (element_size) {
                            1 => bytes[off],
                            2 => std.mem.readInt(u16, bytes[off..][0..2], .little),
                            4 => std.mem.readInt(u32, bytes[off..][0..4], .little),
                            else => return error.BadIndexSize,
                        };
                        dst[i] += @intCast(vertices.items.len);
                    }
                    indices_count = @intCast(acc.count);
                }

                const pos_accessor_idx = primitive.attributes.map.get("POSITION") orelse return error.NoPosition;
                const pos_accessor = gltf.accessors.?[pos_accessor_idx];
                const pos_buffer_view = gltf.bufferViews.?[pos_accessor.bufferView.?];
                const pos_offset = (pos_accessor.byteOffset + pos_buffer_view.byteOffset);
                std.debug.assert(pos_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
                const positions = std.mem.bytesAsSlice(
                    [3]f32,
                    bin[pos_offset .. pos_offset + pos_accessor.count * @sizeOf([3]f32)],
                );

                var base_color: [4]f32 = .{ 1, 0, 0, 1 };
                if (primitive.material) |material_index| {
                    if (gltf.materials) |materials| {
                        if (materials[material_index].pbrMetallicRoughness) |metallic_roughness| {
                            base_color = metallic_roughness.baseColorFactor;
                        }
                    }
                }

                surfaces.appendAssumeCapacity(.{
                    .index_count = indices_count,
                    .index_start = indices_start,
                    .material_index = if (primitive.material) |material_index| original_material_count + material_index else null,
                });

                const uvs: ?[]align(1) const [2]f32 = if (primitive.attributes.map.get("TEXCOORD_0")) |uv_accessor_idx| blk: {
                    const uv_accessor = gltf.accessors.?[uv_accessor_idx];
                    std.debug.assert(uv_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
                    const uv_buffer_view = gltf.bufferViews.?[uv_accessor.bufferView.?];
                    const uv_offset = (uv_accessor.byteOffset + uv_buffer_view.byteOffset);
                    break :blk std.mem.bytesAsSlice(
                        [2]f32,
                        bin[uv_offset .. uv_offset + uv_accessor.count * @sizeOf([2]f32)],
                    );
                } else null;

                const normal_accessor_idx = primitive.attributes.map.get("NORMAL") orelse return error.NoNormal;
                const normal_accessor = gltf.accessors.?[normal_accessor_idx];
                std.debug.assert(normal_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
                const normal_buffer_view = gltf.bufferViews.?[normal_accessor.bufferView.?];
                const normal_offset = (normal_accessor.byteOffset + normal_buffer_view.byteOffset);
                const normals = std.mem.bytesAsSlice(
                    [3]f32,
                    bin[normal_offset .. normal_offset + normal_accessor.count * @sizeOf([3]f32)],
                );

                if (comptime @hasField(VertexType, "joint_indices")) {
                    const joint_accessor_idx = primitive.attributes.map.get("JOINTS_0") orelse return error.NoJoints;
                    const joint_accessor = gltf.accessors.?[joint_accessor_idx];
                    std.debug.assert(joint_accessor.componentType == @intFromEnum(zgltf.ComponentType.unsigned_byte));
                    const joint_buffer_view = gltf.bufferViews.?[joint_accessor.bufferView.?];
                    const joint_offset = (joint_accessor.byteOffset + joint_buffer_view.byteOffset);
                    const joints = std.mem.bytesAsSlice(
                        [4]u8,
                        bin[joint_offset .. joint_offset + joint_accessor.count * @sizeOf([4]u8)],
                    );

                    const weights_accessor_idx = primitive.attributes.map.get("WEIGHTS_0") orelse return error.NoWeights;
                    const weights_accessor = gltf.accessors.?[weights_accessor_idx];
                    std.debug.assert(weights_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
                    std.debug.assert(weights_accessor.type == .VEC4);
                    const weights_buffer_view = gltf.bufferViews.?[weights_accessor.bufferView.?];
                    const weights_offset = (weights_accessor.byteOffset + weights_buffer_view.byteOffset);
                    const weights = std.mem.bytesAsSlice(
                        [4]f32,
                        bin[weights_offset .. weights_offset + weights_accessor.count * @sizeOf([4]f32)],
                    );

                    var dst = try vertices.addManyAsSlice(gpa, pos_accessor.count);
                    for (0..pos_accessor.count) |i| {
                        dst[i] = .{
                            .color = base_color,
                            .normal = normals[i],
                            .position = positions[i],
                            .uv_x = if (uvs) |values| values[i][0] else 0,
                            .uv_y = if (uvs) |values| values[i][1] else 0,
                            .joint_indices = blk: {
                                var joint_indices: [4]i32 = undefined;
                                inline for (0..4) |j| joint_indices[j] = joints[i][j];
                                break :blk joint_indices;
                            },
                            .joint_weights = blk: {
                                var joint_weights: [4]f32 = undefined;
                                inline for (0..4) |j| joint_weights[j] = weights[i][j];
                                break :blk joint_weights;
                            },
                        };
                    }
                } else {
                    var dst = try vertices.addManyAsSlice(gpa, pos_accessor.count);
                    for (0..pos_accessor.count) |i| {
                        dst[i] = .{
                            .color = base_color,
                            .normal = normals[i],
                            .position = positions[i],
                            .uv_x = if (uvs) |values| values[i][0] else 0,
                            .uv_y = if (uvs) |values| values[i][1] else 0,
                        };
                    }
                }
            }

            const new_mesh: Mesh = try .init(
                gpa,
                vma,
                mesh.name orelse "mesh",
                device,
                VertexType,
                vertices.items,
                indices.items,
                surfaces.items,
            );
            try resources.meshes.append(gpa, new_mesh);
        };
    }

    const gltf_nodes = gltf.nodes orelse return;
    const node_map = try gpa.alloc(usize, gltf_nodes.len);
    defer gpa.free(node_map);
    {
        const is_child = try gpa.alloc(bool, gltf_nodes.len);
        defer gpa.free(is_child);
        @memset(is_child, false);
        for (gltf_nodes) |gltf_node| {
            if (gltf_node.children) |children| for (children) |child_index| {
                is_child[child_index] = true;
            };
        }
        var stack: std.ArrayList(usize) = .empty;
        defer stack.deinit(gpa);
        for (0..gltf_nodes.len) |gltf_index| {
            if (!is_child[gltf_index]) try stack.append(gpa, gltf_index);
        }
        var sorted_index: usize = 0;
        while (stack.pop()) |gltf_index| {
            node_map[gltf_index] = sorted_index;
            sorted_index += 1;
            if (gltf_nodes[gltf_index].children) |children| for (children) |child_index| {
                try stack.append(gpa, child_index);
            };
        }
        std.debug.assert(sorted_index == gltf_nodes.len);
    }

    _ = try out_nodes.addManyAsSlice(gpa, gltf_nodes.len);
    for (0..gltf_nodes.len) |gltf_index| {
        const gltf_node = gltf_nodes[gltf_index];
        const sorted_index = node_map[gltf_index];
        const scene_node = &out_nodes.items[sorted_index];
        scene_node.* = .{ .skin_id = if (gltf_node.skin) |skin_id| skin_id else null };
        if (gltf_node.mesh) |mesh_id| {
            scene_node.mesh_id = original_mesh_count + mesh_id;
        }

        if (gltf_node.matrix) |matrix| {
            const local_matrix: nz.Mat4x4(f32) = .{ .d = matrix };
            scene_node.rotation = nz.quat.Hamiltonian(f32).fromMat4x4(local_matrix);
            scene_node.translation = local_matrix.vecPosition();
            scene_node.scale = local_matrix.vecScale();
        } else {
            scene_node.translation = if (gltf_node.translation) |translation| translation else @splat(0);
            scene_node.rotation = if (gltf_node.rotation) |rotation| .{
                .w = rotation[3],
                .x = rotation[0],
                .y = rotation[1],
                .z = rotation[2],
            } else nz.quat.Hamiltonian(f32).identity;
            scene_node.scale = if (gltf_node.scale) |scale| scale else @splat(1);
        }
    }
    for (0..gltf_nodes.len) |gltf_index| {
        const gltf_node = gltf_nodes[gltf_index];
        const gltf_children = gltf_node.children orelse continue;
        const sorted_index = node_map[gltf_index];
        const scene_node = &out_nodes.items[sorted_index];
        for (gltf_children) |gltf_child_index| {
            try scene_node.children.append(gpa, node_map[gltf_child_index]);
            out_nodes.items[node_map[gltf_child_index]].parent = sorted_index;
        }
    }
    if (look_node_names) |node_names| {
        const look_nodes = try gpa.alloc(usize, node_names.len);
        errdefer gpa.free(look_nodes);
        for (node_names, look_nodes) |node_name, *node_index| {
            node_index.* = for (gltf_nodes, 0..) |gltf_node, gltf_index| {
                if (std.mem.eql(u8, gltf_node.name orelse "", node_name)) break node_map[gltf_index];
            } else {
                std.log.err("look node \"{s}\" not found; nodes in this file:", .{node_name});
                for (gltf_nodes) |gltf_node| std.log.err("  \"{s}\"", .{gltf_node.name orelse ""});
                std.log.err("in Model.Kind.spec assign one of these", .{});
                return error.LookBoneNotFound;
            };
        }
        out_look_nodes.?.* = look_nodes;
    }

    if (out_skins) |skins| {
        if (gltf.skins) |gltf_skins| {
            const model_skins = try gpa.alloc(Skin, gltf_skins.len);
            for (gltf_skins, model_skins) |skin, *model_skin| {
                const joints = try gpa.alloc(usize, skin.joints.len);
                for (skin.joints, joints) |gltf_joint_index, *joint| {
                    joint.* = node_map[gltf_joint_index];
                }
                var matrices: ?[]nz.Mat4x4(f32) = null;
                if (skin.inverseBindMatrices.? > -1) {
                    const accessor = gltf.accessors.?[skin.inverseBindMatrices.?];
                    const mat_buffer_view = gltf.bufferViews.?[@intCast(accessor.bufferView.?)];
                    const matrix_data = bin[accessor.byteOffset + mat_buffer_view.byteOffset .. accessor.byteOffset + mat_buffer_view.byteOffset + mat_buffer_view.byteLength];
                    matrices = try gpa.alloc(nz.Mat4x4(f32), accessor.count);
                    @memcpy(std.mem.sliceAsBytes(matrices.?), matrix_data);
                }
                model_skin.* = try .init(gpa, skin.name orelse "skin", matrices, joints);
            }
            skins.* = model_skins;
        }
    }

    if (out_clips) |clips| {
        if (gltf.animations) |animations| {
            const model_animations = try gpa.alloc(AnimationClip, animations.len);
            for (animations, model_animations) |gltf_animation, *model_animation| {
                model_animation.* = try .init(gpa, gltf_animation.name orelse "animation", gltf_animation.samplers.len, gltf_animation.channels.len);
                for (gltf_animation.samplers, model_animation.samplers) |sampler, *model_sampler| {
                    const in_sampler_accessor = gltf.accessors.?[sampler.input];
                    const out_sampler_accessor = gltf.accessors.?[sampler.output];

                    model_sampler.* = .{
                        .inputs = try gpa.alloc(f32, in_sampler_accessor.count),
                        .outputs = try gpa.alloc(nz.Vec4(f32), out_sampler_accessor.count),
                    };

                    const in_sampler_buffer_view = gltf.bufferViews.?[@intCast(in_sampler_accessor.bufferView.?)];
                    const in_sampler_offset = in_sampler_accessor.byteOffset + in_sampler_buffer_view.byteOffset;
                    const in_sampler_data = bin[in_sampler_offset .. in_sampler_offset + in_sampler_buffer_view.byteLength];
                    for (model_sampler.inputs, 0..) |*input, i| {
                        input.* = @bitCast(in_sampler_data[i * 4 ..][0..4].*);
                    }
                    for (model_sampler.inputs) |input| {
                        if (input < model_animation.start) model_animation.start = input;
                        if (input > model_animation.end) model_animation.end = input;
                    }

                    const out_sampler_buffer_view = gltf.bufferViews.?[@intCast(out_sampler_accessor.bufferView.?)];
                    const offset = out_sampler_accessor.byteOffset + out_sampler_buffer_view.byteOffset;
                    const out_sampler_data = bin[offset .. offset + out_sampler_buffer_view.byteLength];
                    switch (out_sampler_accessor.type) {
                        .VEC3 => {
                            for (model_sampler.outputs, 0..) |*output, i| {
                                const value: [3]f32 = @bitCast(out_sampler_data[i * 12 ..][0..12].*);
                                output.* = .{ value[0], value[1], value[2], 0 };
                            }
                        },
                        .VEC4 => {
                            for (model_sampler.outputs, 0..) |*output, i| {
                                const value: [4]f32 = @bitCast(out_sampler_data[i * 16 ..][0..16].*);
                                output.* = value;
                            }
                        },
                        else => return error.UnsupportedAnimationOutput,
                    }
                }
                for (gltf_animation.channels, model_animation.channels) |channel, *model_channel| {
                    model_channel.* = .{
                        .path = switch (channel.target.coreKind() orelse return error.AnimationTargetPath) {
                            .translation => .translation,
                            .rotation => .rotation,
                            .scale => .scale,
                            .weights => return error.WeightsNotSupported,
                        },
                        .node = node_map[channel.target.node orelse return error.ChannelWithoutNode],
                        .sampler_index = channel.sampler,
                    };
                }
            }
            clips.* = model_animations;
        }
    }
}
