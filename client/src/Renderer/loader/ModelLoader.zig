const ModelLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const shared = @import("shared");
const entity = shared.entity;
const AssetServer = @import("../../AssetServer.zig");
const Model = @import("../../asset/Model.zig");
const gltf = @import("../../asset/gltf.zig");
const Mesh = @import("../Vulkan/Mesh.zig");
const Image = @import("../Vulkan/Image.zig");
const Buffer = @import("../Vulkan/Buffer.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

table: *TextureTable,
items: []Item,
files: [][]const u8,
keys: [][]const u8,
files_storage: [][]const u8,
keys_storage: [][]const u8,
specs: []entity.Spec,
specs_storage: []entity.Spec,
reloaded: std.ArrayList(u32),
interface: AssetServer.Loader,

pub const Item = struct {
    model: Model,
    meshes: []Mesh,
    image_slots: []Image.Handle,

    pub const empty: Item = .{
        .model = .empty,
        .meshes = &.{},
        .image_slots = &.{},
    };
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, table: *TextureTable) !ModelLoader {
    const files_storage = try gpa.alloc([]const u8, entity.all_kinds.len);
    const keys_storage = try gpa.alloc([]const u8, entity.all_kinds.len);
    const specs_storage = try gpa.alloc(entity.Spec, entity.all_kinds.len);
    var count: usize = 0;
    for (entity.all_kinds) |kind| {
        const kind_spec = entity.spec(kind);
        const key = kind_spec.model.key;
        if (!std.mem.endsWith(u8, key, ".glb")) continue;
        const already_known = for (keys_storage[0..count]) |existing| {
            if (std.mem.eql(u8, existing, key)) break true;
        } else false;
        if (already_known) continue;
        keys_storage[count] = key;
        files_storage[count] = key["objects/".len..];
        specs_storage[count] = kind_spec;
        count += 1;
    }
    const files = files_storage[0..count];
    const keys = keys_storage[0..count];
    const specs = specs_storage[0..count];

    const items = try gpa.alloc(Item, count);
    @memset(items, .empty);

    return .{
        .table = table,
        .items = items,
        .files = files,
        .keys = keys,
        .files_storage = files_storage,
        .keys_storage = keys_storage,
        .specs = specs,
        .specs_storage = specs_storage,
        .reloaded = .empty,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "objects",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *ModelLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| self.unloadItem(index);
    gpa.free(self.items);
    gpa.free(self.files_storage);
    gpa.free(self.keys_storage);
    gpa.free(self.specs_storage);
    self.reloaded.deinit(gpa);
}

pub fn findByKey(self: *const ModelLoader, key: []const u8) ?u32 {
    for (self.keys, 0..) |existing, index| {
        if (std.mem.eql(u8, existing, key)) return @intCast(index);
    }
    return null;
}

fn load(loader: *AssetServer.Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ModelLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const io = loader.io;
    const file = try err_file;
    self.unloadItem(index);

    const kind_spec = self.specs[index];
    const item = &self.items[index];
    if (kind_spec.model.skinned) {
        var upload_data = try item.model.parseGlb(Mesh.SkinnedVertex, gpa, io, file, kind_spec.model);
        defer upload_data.deinit(gpa);
        try self.uploadItem(Mesh.SkinnedVertex, gpa, item, upload_data);
    } else {
        var upload_data = try item.model.parseGlb(Mesh.StaticVertex, gpa, io, file, kind_spec.model);
        defer upload_data.deinit(gpa);
        try self.uploadItem(Mesh.StaticVertex, gpa, item, upload_data);
    }
    try item.model.finalize(gpa, kind_spec);
    try self.reloaded.append(gpa, @intCast(index));
}

fn uploadItem(self: *ModelLoader, comptime VertexType: type, gpa: std.mem.Allocator, item: *Item, upload: gltf.UploadData(VertexType)) !void {
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

    item.meshes = meshes;
    item.image_slots = image_slots;
}

fn unload(loader: *AssetServer.Loader, index: usize) void {
    const self: *ModelLoader = @fieldParentPtr("interface", loader);
    self.unloadItem(index);
}

fn unloadItem(self: *ModelLoader, index: usize) void {
    const gpa = self.interface.gpa;
    const item = &self.items[index];
    if (item.meshes.len == 0 and item.model.isEmpty()) return;
    check(c.vkDeviceWaitIdle(self.table.device.handle)) catch {};
    for (item.meshes) |*mesh| mesh.deinit(gpa, self.table.vma);
    gpa.free(item.meshes);
    for (item.image_slots) |slot| self.table.freeSlot(gpa, slot);
    gpa.free(item.image_slots);
    item.model.deinit(gpa);
    item.* = .empty;
}
