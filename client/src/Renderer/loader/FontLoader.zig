const FontLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("../../AssetServer.zig");
const Font = @import("../Vulkan/Font.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

table: *TextureTable,
items: []Font,
interface: AssetServer.Loader,

const font_files = [_][]const u8{"Roboto-Regular.ttf"};

pub fn init(gpa: std.mem.Allocator, io: std.Io, table: *TextureTable) !FontLoader {
    const items = try gpa.alloc(Font, font_files.len);
    for (items) |*font| font.* = .init(table.vma, table.device);

    return .{
        .table = table,
        .items = items,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "fonts",
            .files = &font_files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *FontLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| self.unloadItem(index);
    gpa.free(self.items);
}

fn load(loader: *AssetServer.Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    const file = try err_file;
    self.unloadItem(index);
    const font = &self.items[index];
    const atlas_image = try font.load(loader.gpa, loader.io, file);
    font.atlas_texture = try self.table.allocSlot(loader.gpa, atlas_image, font.sampler, null);
}

fn unload(loader: *AssetServer.Loader, index: usize) void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    self.unloadItem(index);
}

fn unloadItem(self: *FontLoader, index: usize) void {
    const font = &self.items[index];
    if (font.sampler == null) return;
    self.table.freeSlot(self.interface.gpa, font.atlas_texture);
    check(c.vkDeviceWaitIdle(self.table.device.handle)) catch {};
    c.vkDestroySampler(self.table.device.handle, font.sampler, null);
    font.sampler = null;
}
