const std = @import("std");
const nz = @import("numz");
const zgltf = @import("zgltf");
const Bitmap = @import("Bitmap.zig");
const Node = @import("Node.zig");
const Skin = @import("Model.zig").Skin;
const AnimationClip = @import("AnimationClip.zig");

pub const Glb = struct {
    content: []const u8,
    loaded: zgltf.LoadedGlb,
    gltf: zgltf.Gltf,
    bin: []const u8,

    pub fn parse(gpa: std.mem.Allocator, content: []const u8) !Glb {
        var loaded = try zgltf.parseGlbSlice(gpa, content);
        errdefer loaded.deinit();
        const bin = loaded.bin orelse return error.MissingBin;

        return .{ .content = content, .loaded = loaded, .gltf = loaded.parsed.value, .bin = bin };
    }

    pub fn isSkinned(self: *const Glb) bool {
        const skins = self.gltf.skins orelse return false;
        return skins.len > 0;
    }

    pub fn deinit(self: *Glb, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.loaded.deinit();
    }
};

pub const SamplerDesc = struct {
    mag_linear: bool,
    min_linear: bool,
};

pub fn UploadData(comptime VertexType: type) type {
    return struct {
        const Self = @This();

        pub const Surface = struct {
            index_start: u32,
            index_count: u32,
            image_index: ?usize,
            material_missing: bool,
            transparent: bool,
        };

        pub const Mesh = struct {
            name: []const u8,
            vertices: []VertexType,
            indices: []u32,
            surfaces: []Surface,
        };

        samplers: []SamplerDesc = &.{},
        images: []Bitmap = &.{},
        image_sampler: []?usize = &.{},
        meshes: []Mesh = &.{},

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.samplers);
            for (self.images) |*image| image.deinit();
            gpa.free(self.images);
            gpa.free(self.image_sampler);
            for (self.meshes) |mesh| {
                gpa.free(mesh.name);
                gpa.free(mesh.vertices);
                gpa.free(mesh.indices);
                gpa.free(mesh.surfaces);
            }
            gpa.free(self.meshes);
            self.* = .{};
        }
    };
}

pub fn parseScene(
    comptime VertexType: type,
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    out_nodes: *std.ArrayList(Node),
    out_node_names: *[][]const u8,
    out_skins: ?*[]Skin,
    out_clips: ?*[]AnimationClip,
) !UploadData(VertexType) {
    var upload: UploadData(VertexType) = .{};
    errdefer upload.deinit(gpa);

    upload.samplers = try parseSamplers(gpa, gltf);
    try decodeImages(gpa, gltf, bin, &upload.images, &upload.image_sampler);

    const materials = try parseMaterials(gpa, gltf, upload.image_sampler);
    defer gpa.free(materials);
    upload.meshes = try parseMeshes(VertexType, gpa, gltf, bin, materials);

    const gltf_nodes = gltf.nodes orelse return upload;
    const node_map = try sortNodes(gpa, gltf_nodes);
    defer gpa.free(node_map);
    try parseNodes(gpa, gltf_nodes, node_map, out_nodes, out_node_names);
    if (out_skins) |skins| skins.* = try parseSkins(gpa, gltf, bin, node_map);
    if (out_clips) |clips| clips.* = try parseClips(gpa, gltf, bin, node_map);
    return upload;
}

/// The elements of a tightly packed accessor as a slice of `T`.
fn accessorSlice(
    comptime T: type,
    gltf: zgltf.Gltf,
    bin: []const u8,
    accessor_index: usize,
) []align(1) const T {
    const accessor = gltf.accessors.?[accessor_index];
    const buffer_view = gltf.bufferViews.?[@intCast(accessor.bufferView.?)];
    const offset = accessor.byteOffset + buffer_view.byteOffset;
    return std.mem.bytesAsSlice(T, bin[offset .. offset + accessor.count * @sizeOf(T)]);
}

fn attributeSlice(
    comptime T: type,
    gltf: zgltf.Gltf,
    bin: []const u8,
    primitive: zgltf.Primitive,
    name: []const u8,
) ?[]align(1) const T {
    const accessor_index = primitive.attributes.map.get(name) orelse return null;
    return accessorSlice(T, gltf, bin, accessor_index);
}

fn parseSamplers(gpa: std.mem.Allocator, gltf: zgltf.Gltf) ![]SamplerDesc {
    const samplers = gltf.samplers orelse return &.{};
    const descs = try gpa.alloc(SamplerDesc, samplers.len);
    for (samplers, descs) |sampler, *desc| desc.* = .{
        .mag_linear = if (sampler.magFilter) |filter| filter == .linear else true,
        .min_linear = if (sampler.minFilter) |filter| filter != .nearest else true,
    };
    return descs;
}

fn decodeImages(
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    out_images: *[]Bitmap,
    out_image_sampler: *[]?usize,
) !void {
    const images = gltf.images orelse return;
    const decoded_images = try gpa.alloc(Bitmap, images.len);
    @memset(decoded_images, .{});
    out_images.* = decoded_images;
    const image_sampler = try gpa.alloc(?usize, images.len);
    @memset(image_sampler, null);
    out_image_sampler.* = image_sampler;

    const decode_tasks = try gpa.alloc(Bitmap.Task, images.len);
    defer {
        for (decode_tasks) |*task| if (task.uri) |uri| gpa.free(uri);
        gpa.free(decode_tasks);
    }
    for (images, decode_tasks, decoded_images) |image, *task, *decoded| {
        task.* = .{ .result = decoded };
        if (image.uri) |uri| {
            if (std.mem.startsWith(u8, uri, "data:")) return error.DataNotSupported;
            task.uri = try gpa.dupeSentinel(u8, uri, 0);
            continue;
        }
        const buffer_view_index = image.bufferView orelse return error.FailedToLoadGLTFImage;
        const buffer_view = (gltf.bufferViews orelse return error.MissingBufferViews)[buffer_view_index];
        task.bytes = bin[buffer_view.byteOffset .. buffer_view.byteOffset + buffer_view.byteLength];
    }

    try Bitmap.decodeAll(gpa, decode_tasks);
    for (decoded_images) |*decoded| {
        if (decoded.err) |err| return err;
        if (decoded.pixels == null) return error.LoadingStbi;
    }
}

const Material = struct {
    image: ?usize,
    transparent: bool,
    base_color: [4]f32,
};

fn parseMaterials(gpa: std.mem.Allocator, gltf: zgltf.Gltf, image_sampler: []?usize) ![]Material {
    const materials = gltf.materials orelse return &.{};
    const parsed = try gpa.alloc(Material, materials.len);
    for (materials, parsed) |material, *out| {
        out.* = .{
            .image = null,
            .transparent = material.alphaMode == .BLEND,
            .base_color = .{ 1, 1, 1, 1 },
        };
        const metallic_roughness = material.pbrMetallicRoughness orelse continue;
        out.base_color = metallic_roughness.baseColorFactor;
        const base_texture = metallic_roughness.baseColorTexture orelse continue;
        const texture = gltf.textures.?[base_texture.index];
        const image_index = texture.source orelse continue;
        out.image = image_index;
        if (texture.sampler) |sampler_index| image_sampler[image_index] = sampler_index;
    }
    return parsed;
}

fn parseMeshes(
    comptime VertexType: type,
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    materials: []const Material,
) ![]UploadData(VertexType).Mesh {
    const meshes = gltf.meshes orelse return &.{};
    var mesh_list: std.ArrayList(UploadData(VertexType).Mesh) = .empty;
    errdefer {
        for (mesh_list.items) |mesh| {
            gpa.free(mesh.name);
            gpa.free(mesh.vertices);
            gpa.free(mesh.indices);
            gpa.free(mesh.surfaces);
        }
        mesh_list.deinit(gpa);
    }
    for (meshes) |mesh| {
        var surfaces: std.ArrayList(
            UploadData(VertexType).Surface,
        ) = try .initCapacity(gpa, mesh.primitives.len);
        errdefer surfaces.deinit(gpa);
        var vertices: std.ArrayList(VertexType) = .empty;
        errdefer vertices.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        errdefer indices.deinit(gpa);

        for (mesh.primitives) |primitive| {
            const index_start: u32 = @intCast(indices.items.len);
            try appendIndices(gpa, gltf, bin, primitive, @intCast(vertices.items.len), &indices);
            const material: ?Material = if (primitive.material) |index| materials[index] else null;
            surfaces.appendAssumeCapacity(.{
                .index_start = index_start,
                .index_count = @intCast(indices.items.len - index_start),
                .image_index = if (material) |found| found.image else null,
                .material_missing = material == null,
                .transparent = if (material) |found| found.transparent else false,
            });
            const base_color = if (material) |found| found.base_color else .{ 1, 1, 1, 1 };
            try appendVertices(VertexType, gpa, gltf, bin, primitive, base_color, &vertices);
        }

        try mesh_list.append(gpa, .{
            .name = try gpa.dupe(u8, mesh.name orelse "mesh"),
            .vertices = try vertices.toOwnedSlice(gpa),
            .indices = try indices.toOwnedSlice(gpa),
            .surfaces = try surfaces.toOwnedSlice(gpa),
        });
    }
    return mesh_list.toOwnedSlice(gpa);
}

fn appendIndices(
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    primitive: zgltf.Primitive,
    base_vertex: u32,
    indices: *std.ArrayList(u32),
) !void {
    var accessor = gltf.accessors.?[primitive.indices.?];
    const buffer_view = gltf.bufferViews.?[accessor.bufferView.?];
    const offset = buffer_view.byteOffset + accessor.byteOffset;
    const element_size = try accessor.elementSize();
    const bytes = bin[offset .. offset + accessor.count * element_size];
    const destination = try indices.addManyAsSlice(gpa, accessor.count);
    for (destination, 0..) |*index, i| {
        const at = i * element_size;
        const value: u32 = switch (element_size) {
            1 => bytes[at],
            2 => std.mem.readInt(u16, bytes[at..][0..2], .little),
            4 => std.mem.readInt(u32, bytes[at..][0..4], .little),
            else => return error.BadIndexSize,
        };
        index.* = value + base_vertex;
    }
}

fn appendVertices(
    comptime VertexType: type,
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    primitive: zgltf.Primitive,
    base_color: [4]f32,
    vertices: *std.ArrayList(VertexType),
) !void {
    const positions = attributeSlice(
        [3]f32,
        gltf,
        bin,
        primitive,
        "POSITION",
    ) orelse return error.NoPosition;
    const normals = attributeSlice(
        [3]f32,
        gltf,
        bin,
        primitive,
        "NORMAL",
    ) orelse return error.NoNormal;
    const uvs = attributeSlice([2]f32, gltf, bin, primitive, "TEXCOORD_0");
    const destination = try vertices.addManyAsSlice(gpa, positions.len);
    for (destination, 0..) |*vertex, i| {
        vertex.color = base_color;
        vertex.normal = normals[i];
        vertex.position = positions[i];
        vertex.uv_x = if (uvs) |values| values[i][0] else 0;
        vertex.uv_y = if (uvs) |values| values[i][1] else 0;
    }
    if (comptime !@hasField(VertexType, "joint_indices")) return;
    const joints = attributeSlice([4]u8, gltf, bin, primitive, "JOINTS_0");
    const weights = attributeSlice([4]f32, gltf, bin, primitive, "WEIGHTS_0");
    for (destination, 0..) |*vertex, i| {
        inline for (0..4) |j| {
            vertex.joint_indices[j] = if (joints) |joint| joint[i][j] else 0;
            vertex.joint_weights[j] = if (weights) |weight| weight[i][j] else if (j == 0) 1 else 0;
        }
    }
}

/// Map from glTF node index to a depth-first order where parents come before children.
fn sortNodes(gpa: std.mem.Allocator, gltf_nodes: []const zgltf.Node) ![]usize {
    const node_map = try gpa.alloc(usize, gltf_nodes.len);
    errdefer gpa.free(node_map);
    const is_child = try gpa.alloc(bool, gltf_nodes.len);
    defer gpa.free(is_child);
    @memset(is_child, false);
    for (gltf_nodes) |gltf_node| {
        const children = gltf_node.children orelse continue;
        for (children) |child_index| is_child[child_index] = true;
    }
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (is_child, 0..) |child, gltf_index| {
        if (!child) try stack.append(gpa, gltf_index);
    }
    var sorted_index: usize = 0;
    while (stack.pop()) |gltf_index| {
        node_map[gltf_index] = sorted_index;
        sorted_index += 1;
        const children = gltf_nodes[gltf_index].children orelse continue;
        for (children) |child_index| try stack.append(gpa, child_index);
    }
    std.debug.assert(sorted_index == gltf_nodes.len);
    return node_map;
}

fn parseNodes(
    gpa: std.mem.Allocator,
    gltf_nodes: []const zgltf.Node,
    node_map: []const usize,
    out_nodes: *std.ArrayList(Node),
    out_node_names: *[][]const u8,
) !void {
    _ = try out_nodes.addManyAsSlice(gpa, gltf_nodes.len);
    for (gltf_nodes, node_map) |gltf_node, sorted_index| {
        out_nodes.items[sorted_index] = localNode(gltf_node);
    }
    for (gltf_nodes, node_map) |gltf_node, sorted_index| {
        const children = gltf_node.children orelse continue;
        for (children) |child_index| out_nodes.items[node_map[child_index]].parent = sorted_index;
    }

    const node_names = try gpa.alloc([]const u8, out_nodes.items.len);
    errdefer gpa.free(node_names);
    for (node_names) |*name| name.* = "";
    for (gltf_nodes, node_map) |gltf_node, sorted_index| {
        node_names[sorted_index] = try gpa.dupe(u8, gltf_node.name orelse "");
    }
    out_node_names.* = node_names;
}

fn localNode(gltf_node: zgltf.Node) Node {
    var node: Node = .{ .skin_id = if (gltf_node.skin) |skin_id| skin_id else null };
    if (gltf_node.mesh) |mesh_id| node.mesh_id = mesh_id;
    if (gltf_node.matrix) |matrix| {
        const local_matrix: nz.Mat4x4(f32) = .{ .d = matrix };
        node.rotation = nz.quat.Hamiltonian(f32).fromMat4x4(local_matrix);
        node.translation = local_matrix.vecPosition();
        node.scale = local_matrix.vecScale();
        return node;
    }
    node.translation = gltf_node.translation orelse @splat(0);
    node.rotation = if (gltf_node.rotation) |rotation|
        .{ .w = rotation[3], .x = rotation[0], .y = rotation[1], .z = rotation[2] }
    else
        nz.quat.Hamiltonian(f32).identity;
    node.scale = gltf_node.scale orelse @splat(1);
    return node;
}

fn parseSkins(
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    node_map: []const usize,
) ![]Skin {
    const gltf_skins = gltf.skins orelse return &.{};
    const skins = try gpa.alloc(Skin, gltf_skins.len);
    for (gltf_skins, skins) |gltf_skin, *skin| {
        const joints = try gpa.alloc(usize, gltf_skin.joints.len);
        for (gltf_skin.joints, joints) |gltf_joint_index, *joint| joint.* = node_map[gltf_joint_index];
        var matrices: ?[]nz.Mat4x4(f32) = null;
        if (gltf_skin.inverseBindMatrices.? > -1) {
            const source = accessorSlice(
                [16]f32,
                gltf,
                bin,
                @intCast(gltf_skin.inverseBindMatrices.?),
            );
            matrices = try gpa.alloc(nz.Mat4x4(f32), source.len);
            for (matrices.?, source) |*matrix, values| matrix.* = .{ .d = values };
        }
        skin.* = try .init(gpa, gltf_skin.name orelse "skin", matrices, joints);
    }
    return skins;
}

fn parseClips(
    gpa: std.mem.Allocator,
    gltf: zgltf.Gltf,
    bin: []const u8,
    node_map: []const usize,
) ![]AnimationClip {
    const animations = gltf.animations orelse return &.{};
    const clips = try gpa.alloc(AnimationClip, animations.len);
    for (animations, clips) |animation, *clip| {
        clip.* = try .init(
            gpa,
            animation.name orelse "animation",
            animation.samplers.len,
            animation.channels.len,
        );
        for (animation.samplers, clip.samplers) |sampler, *clip_sampler| {
            const inputs = accessorSlice(f32, gltf, bin, sampler.input);
            clip_sampler.* = .{
                .inputs = try gpa.alloc(f32, inputs.len),
                .outputs = try gpa.alloc(nz.Vec4(f32), gltf.accessors.?[sampler.output].count),
            };
            for (clip_sampler.inputs, inputs) |*input, value| {
                input.* = value;
                clip.start = @min(clip.start, value);
                clip.end = @max(clip.end, value);
            }
            try readSamplerOutputs(gltf, bin, sampler.output, clip_sampler.outputs);
        }
        for (animation.channels, clip.channels) |channel, *clip_channel| clip_channel.* = .{
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
    return clips;
}

fn readSamplerOutputs(
    gltf: zgltf.Gltf,
    bin: []const u8,
    accessor_index: usize,
    outputs: []nz.Vec4(f32),
) !void {
    switch (gltf.accessors.?[accessor_index].type) {
        .VEC3 => for (outputs, accessorSlice([3]f32, gltf, bin, accessor_index)) |*output, value| {
            output.* = .{ value[0], value[1], value[2], 0 };
        },
        .VEC4 => for (outputs, accessorSlice([4]f32, gltf, bin, accessor_index)) |*output, value| {
            output.* = value;
        },
        else => return error.UnsupportedAnimationOutput,
    }
}
