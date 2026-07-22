const TextureLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const shared = @import("shared");
const entity = shared.entity;
const Loader = @import("../../AssetServer.zig").Loader;
const Image = @import("../Vulkan/Image.zig");
const Bitmap = @import("../../asset/Bitmap.zig");
const TextureTable = @import("TextureTable.zig");

const skybox_file = "skybox_cubemap.png";

table: *TextureTable,
items: []?Image.Handle,
interface: Loader,

pub fn init(gpa: std.mem.Allocator, io: std.Io, table: *TextureTable) !TextureLoader {
    const spec_capacity = entity.all_kinds.len + 2;
    const files = try gpa.alloc([]const u8, spec_capacity);
    files[0] = skybox_file;
    files[1] = TextureTable.crosshair_texture_path["textures/".len..];
    var count: usize = 2;
    for (entity.all_kinds) |kind| {
        const icon = entity.spec(kind).icon orelse continue;
        const file = icon["textures/".len..];
        const already_known = for (files[0..count]) |existing| {
            if (std.mem.eql(u8, existing, file)) break true;
        } else false;
        if (already_known) continue;
        files[count] = file;
        count += 1;
    }

    const items = try gpa.alloc(?Image.Handle, count);
    @memset(items, null);

    return .{
        .table = table,
        .items = items,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "textures",
            .files = try gpa.realloc(files, count),
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *TextureLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| unload(&self.interface, index);
    gpa.free(self.items);
    gpa.free(self.interface.files);
}

fn decodeFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !Bitmap {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);

    var decoded: Bitmap = .{};
    var decode_tasks: [1]Bitmap.Task = .{.{ .result = &decoded, .bytes = bytes }};
    try Bitmap.decodeAll(gpa, &decode_tasks);
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;
    return decoded;
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *TextureLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const table = self.table;
    const file = try err_file;
    unload(&self.interface, index);

    var decoded = try decodeFile(gpa, loader.io, file);
    defer decoded.deinit();

    if (std.mem.eql(u8, loader.files[index], skybox_file)) return self.loadSkybox(gpa, decoded);

    var image: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = @intCast(decoded.width), .height = @intCast(decoded.height), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer image.deinit(table.vma, table.device);
    try image.uploadDataToImage(table.vma, table.device, decoded.pixels, 4, 0);

    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "textures/{s}", .{loader.files[index]});
    self.items[index] = try table.allocSlot(gpa, image, table.samplers.items[0], path);
}

fn loadSkybox(self: *TextureLoader, gpa: std.mem.Allocator, decoded: Bitmap) !void {
    const table = self.table;
    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);

    var cubemap: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = face_size, .height = face_size, .depth = 1 },
        .cube_map,
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer cubemap.deinit(table.vma, table.device);

    const channels: u32 = 4;
    const row_bytes = face_size * channels;
    const data = try gpa.alloc(u8, face_size * face_size * channels);
    defer gpa.free(data);
    for (0..6) |face| {
        var x_start: u32, var y_start: u32 = switch (face) {
            0 => .{ 2, 1 },
            1 => .{ 0, 1 },
            2 => .{ 1, 0 },
            3 => .{ 1, 2 },
            4 => .{ 1, 1 },
            5 => .{ 3, 1 },
            else => unreachable,
        };
        x_start *= face_size;
        y_start *= face_size;

        for (0..face_size) |y| {
            const dst = y * row_bytes;
            const src = ((y_start + y) * width + x_start) * channels;
            @memcpy(data[dst..][0..row_bytes], decoded.pixels[src..][0..row_bytes]);
        }

        try cubemap.uploadDataToImage(table.vma, table.device, data.ptr, channels, @intCast(face));
    }

    table.setSkybox(cubemap);
}

fn unload(loader: *Loader, index: usize) void {
    const self: *TextureLoader = @fieldParentPtr("interface", loader);
    if (self.items[index]) |image_handle| {
        self.table.freeSlot(loader.gpa, image_handle);
        self.items[index] = null;
    }
}
