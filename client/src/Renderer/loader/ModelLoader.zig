const ModelLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const shared = @import("shared");
const entity = shared.entity;
const Loader = @import("../../AssetServer.zig").Loader;
const Model = @import("../../asset/Model.zig");
const gltf = @import("../../asset/gltf.zig");
const Mesh = @import("../Vulkan/Mesh.zig");
const Image = @import("../Vulkan/Image.zig");
const Buffer = @import("../Vulkan/Buffer.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

table: *TextureTable,
items: []Entry,
reloaded: std.ArrayList(u32),
interface: Loader,

pub const Entry = struct {
    path: []const u8,
    kind_spec: entity.Spec,
    model: Model,
    meshes: []Mesh,
    image_slots: []Image.Handle,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, table: *TextureTable) !ModelLoader {
    const files = try gpa.alloc([]const u8, entity.all_kinds.len);
    const entries_storage = try gpa.alloc(Entry, entity.all_kinds.len);
    var count: usize = 0;
    for (entity.all_kinds) |kind| {
        const kind_spec = entity.spec(kind);
        const path = kind_spec.model.path;
        if (!std.mem.endsWith(u8, path, ".glb")) continue;
        entries_storage[count] = .{
            .path = path,
            .kind_spec = kind_spec,
            .model = .empty,
            .meshes = &.{},
            .image_slots = &.{},
        };
        files[count] = path["objects/".len..];
        count += 1;
    }
    const entries = try gpa.realloc(entries_storage, count);

    return .{
        .table = table,
        .items = entries,
        .reloaded = .empty,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "objects",
            .files = try gpa.realloc(files, count),
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *ModelLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| unload(&self.interface, index);
    gpa.free(self.items);
    gpa.free(self.interface.files);
    self.reloaded.deinit(gpa);
}

pub fn findByPath(self: *const ModelLoader, path: []const u8) ?u32 {
    for (self.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return @intCast(index);
    }
    return null;
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ModelLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const io = loader.io;
    const file = try err_file;
    unload(loader, index);

    const entry = &self.items[index];
    if (entry.kind_spec.model.skinned) {
        var upload_data = try entry.model.parseGlb(Mesh.SkinnedVertex, gpa, io, file, entry.kind_spec);
        defer upload_data.deinit(gpa);
        try self.uploadToGpu(Mesh.SkinnedVertex, gpa, entry, upload_data);
    } else {
        var upload_data = try entry.model.parseGlb(Mesh.StaticVertex, gpa, io, file, entry.kind_spec);
        defer upload_data.deinit(gpa);
        try self.uploadToGpu(Mesh.StaticVertex, gpa, entry, upload_data);
    }
    try self.reloaded.append(gpa, @intCast(index));
}

fn uploadToGpu(self: *ModelLoader, comptime VertexType: type, gpa: std.mem.Allocator, entry: *Entry, upload: gltf.UploadData(VertexType)) !void {
    const device = self.table.device;
    const vma = self.table.vma;

    const glb_samplers = try gpa.alloc(c.VkSampler, upload.samplers.len);
    defer gpa.free(glb_samplers);
    for (upload.samplers, glb_samplers) |desc, *sampler| {
        sampler.* = try self.table.addSampler(gpa, desc.mag_linear, desc.min_linear);
    }

    const image_slots = try gpa.alloc(Image.Handle, upload.images.len);
    errdefer gpa.free(image_slots);
    if (upload.images.len > 0) {
        var upload_buffers: std.ArrayList(Buffer) = .empty;
        defer {
            for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(vma);
            upload_buffers.deinit(gpa);
        }
        const upload_cmd = try device.beginImmediateCommand();
        for (upload.images, upload.image_sampler, image_slots) |decoded_image, sampler_index, *slot| {
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
            try new_image.recordUploadDataToImage(gpa, vma, device, upload_cmd, decoded_image.pixels, 0, 4, &upload_buffers);
            const sampler = if (sampler_index) |glb_index| glb_samplers[glb_index] else self.table.samplers.items[0];
            slot.* = try self.table.allocSlot(gpa, new_image, sampler, null);
        }
        try device.endImmediateCommand(upload_cmd);
    }

    const meshes = try gpa.alloc(Mesh, upload.meshes.len);
    errdefer gpa.free(meshes);
    for (upload.meshes, meshes) |mesh_data, *mesh| {
        const surfaces = try gpa.alloc(Mesh.GeoSurface, mesh_data.surfaces.len);
        defer gpa.free(surfaces);
        for (mesh_data.surfaces, surfaces) |surface_data, *surface| surface.* = .{
            .index_start = surface_data.index_start,
            .index_count = surface_data.index_count,
            .texture = if (surface_data.image_index) |image_index| image_slots[image_index] else .blank,
        };
        mesh.* = try .init(gpa, vma, mesh_data.name, device, VertexType, mesh_data.vertices, mesh_data.indices, surfaces);
    }

    entry.meshes = meshes;
    entry.image_slots = image_slots;
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ModelLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const entry = &self.items[index];
    if (entry.meshes.len == 0 and entry.model.isEmpty()) return;
    check(c.vkDeviceWaitIdle(self.table.device.handle)) catch {};
    for (entry.meshes) |*mesh| mesh.deinit(gpa, self.table.vma);
    gpa.free(entry.meshes);
    entry.meshes = &.{};
    for (entry.image_slots) |slot| self.table.freeSlot(gpa, slot);
    gpa.free(entry.image_slots);
    entry.image_slots = &.{};
    entry.model.deinit(gpa);
    entry.model = .empty;
}
