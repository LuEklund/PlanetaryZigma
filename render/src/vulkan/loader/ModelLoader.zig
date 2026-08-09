const ModelLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const shared = @import("shared");
const contract = @import("render");
const gltf = contract.gltf;
const DrawList = @import("render").DrawList;
const Mesh = @import("../Vulkan/Mesh.zig");
const Image = @import("../Vulkan/Image.zig");
const Buffer = @import("../Vulkan/Buffer.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

gpa: std.mem.Allocator,
table: *TextureTable,
entries: [contract.max_models]Entry,

/// The GPU half only — the CPU `Model` lives in the caller-owned `ModelTable`.
pub const Entry = struct {
    meshes: []Mesh,
    image_slots: []Image.Handle,
    images: []Image,
};

pub fn init(self: *ModelLoader, gpa: std.mem.Allocator, table: *TextureTable) !void {
    self.* = .{
        .gpa = gpa,
        .table = table,
        .entries = @splat(.{ .meshes = &.{}, .image_slots = &.{}, .images = &.{} }),
    };
}

pub fn deinit(self: *ModelLoader) void {
    for (0..self.entries.len) |index| self.release(index);
}

fn release(self: *ModelLoader, index: usize) void {
    const gpa = self.gpa;
    const entry = &self.entries[index];
    if (entry.meshes.len == 0) return;
    check(c.vkDeviceWaitIdle(self.table.device.handle)) catch {};
    for (entry.meshes) |*mesh| mesh.deinit(gpa, self.table.vma);
    gpa.free(entry.meshes);
    entry.meshes = &.{};
    for (entry.image_slots) |slot| self.table.free(gpa, @intFromEnum(slot));
    gpa.free(entry.image_slots);
    entry.image_slots = &.{};
    for (entry.images) |*image| image.deinit(self.table.vma, self.table.device);
    gpa.free(entry.images);
    entry.images = &.{};
}

/// Build the GPU half from geometry the producer already parsed.
pub fn apply(self: *ModelLoader, upload: DrawList.ModelUpload) !void {
    self.release(upload.index);
    const entry = &self.entries[upload.index];
    switch (upload.data) {
        .static => |data| try self.uploadToGpu(Mesh.StaticVertex, self.gpa, entry, data),
        .skinned => |data| try self.uploadToGpu(Mesh.SkinnedVertex, self.gpa, entry, data),
    }
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
    const images = try gpa.alloc(Image, upload.images.len);
    errdefer gpa.free(images);
    if (upload.images.len > 0) {
        var upload_buffers: std.ArrayList(Buffer) = .empty;
        defer {
            for (upload_buffers.items) |*upload_buffer| upload_buffer.deinit(vma);
            upload_buffers.deinit(gpa);
        }
        const upload_cmd = try device.beginImmediateCommand();
        for (upload.images, upload.image_sampler, image_slots, images) |decoded_image, sampler_index, *slot, *image| {
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
            const slot_index = self.table.alloc();
            self.table.write(slot_index, new_image.vk_imageview, sampler);
            slot.* = @enumFromInt(slot_index);
            image.* = new_image;
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
            .texture = if (surface_data.material_missing) .material_not_found else if (surface_data.image_index) |image_index| image_slots[image_index] else .blank,
        };
        mesh.* = try .init(gpa, vma, mesh_data.name, device, VertexType, mesh_data.vertices, mesh_data.indices, surfaces);
    }

    entry.meshes = meshes;
    entry.image_slots = image_slots;
    entry.images = images;
}
