const FontLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("../../AssetServer.zig");
const Loader = AssetServer.Loader;
const Font = @import("shared").Font;
const stbTruetype = @import("stb_truetype");
const Image = @import("../Vulkan/Image.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

table: *TextureTable,
items: []Font,
samplers: []c.VkSampler,
atlases: []?Image,
interface: Loader,

/// `fonts` is caller-owned: a loader-owned one would be a pointer into render.so.
pub fn init(self: *FontLoader, gpa: std.mem.Allocator, asset_server: *AssetServer, table: *TextureTable, fonts: []Font) !void {
    std.debug.assert(fonts.len == Font.files.len);
    const items = fonts;
    @memset(items, .empty);
    const samplers = try gpa.alloc(c.VkSampler, Font.files.len);
    @memset(samplers, null);
    const atlases = try gpa.alloc(?Image, Font.files.len);
    @memset(atlases, null);

    self.* = .{
        .table = table,
        .items = items,
        .samplers = samplers,
        .atlases = atlases,
        .interface = .{
            .gpa = gpa,
            .io = asset_server.io,
            .root_path = "fonts",
            .files = Font.files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *FontLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| unload(&self.interface, index);
    gpa.free(self.samplers);
    gpa.free(self.atlases);
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const table = self.table;
    const file = try err_file;
    unload(&self.interface, index);

    const font = &self.items[index];
    const coverage = try bake(font, gpa, loader.io, file);
    defer gpa.free(coverage);

    var atlas_image: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8_UNORM,
        .{ .width = @intCast(Font.atlas_width), .height = @intCast(Font.atlas_height), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer atlas_image.deinit(table.vma, table.device);
    try atlas_image.uploadDataToImage(table.vma, table.device, coverage.ptr, 1, 0);

    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    try check(c.vkCreateSampler(table.device.handle, &sampler_info, null, &self.samplers[index]));

    const atlas_slot = table.alloc();
    table.write(atlas_slot, atlas_image.vk_imageview, self.samplers[index]);
    self.atlases[index] = atlas_image;
    font.atlas_texture_index = @intCast(atlas_slot);
}

fn unload(loader: *Loader, index: usize) void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    if (self.samplers[index] == null) return;
    self.table.free(loader.gpa, self.items[index].atlas_texture_index);
    if (self.atlases[index]) |*atlas| atlas.deinit(self.table.vma, self.table.device);
    self.atlases[index] = null;
    c.vkDestroySampler(self.table.device.handle, self.samplers[index], null);
    self.samplers[index] = null;
    self.items[index] = .empty;
}

fn bake(self: *Font, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);
    std.log.debug("font file size: {d}", .{content.len});

    const coverage = try gpa.alloc(u8, Font.atlas_width * Font.atlas_height);
    errdefer gpa.free(coverage);
    @memset(coverage, 0);

    const padding: c_int = 5;
    const on_edge: u8 = 128;
    const pixel_dist_scale: f32 = @as(f32, on_edge) / @as(f32, padding);

    var info: stbTruetype.stbtt_fontinfo = undefined;
    _ = stbTruetype.stbtt_InitFont(&info, content.ptr, 0);
    const scale = stbTruetype.stbtt_ScaleForPixelHeight(&info, self.size);

    var pen_x: usize = 1;
    var pen_y: usize = 1;
    var row_height: usize = 0;
    for (&self.glyphs, 0..) |*glyph, i| {
        const codepoint: c_int = @intCast(32 + i);
        var advance: c_int = 0;
        var left_bearing: c_int = 0;
        stbTruetype.stbtt_GetCodepointHMetrics(&info, codepoint, &advance, &left_bearing);

        var width: c_int = 0;
        var height: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const sdf = stbTruetype.stbtt_GetCodepointSDF(
            &info,
            scale,
            codepoint,
            padding,
            on_edge,
            pixel_dist_scale,
            &width,
            &height,
            &xoff,
            &yoff,
        );
        defer if (sdf != null) stbTruetype.stbtt_FreeSDF(sdf, null);

        const glyph_w: usize = @intCast(width);
        const glyph_h: usize = @intCast(height);
        if (sdf != null and glyph_w > 0) {
            if (pen_x + glyph_w + 1 > Font.atlas_width) {
                pen_x = 1;
                pen_y += row_height + 1;
                row_height = 0;
            }
            for (0..glyph_h) |row| {
                const src = sdf[row * glyph_w ..][0..glyph_w];
                const dst = coverage[(pen_y + row) * Font.atlas_width + pen_x ..][0..glyph_w];
                @memcpy(dst, src);
            }
        }

        glyph.* = .{
            .u0 = @as(f32, @floatFromInt(pen_x)) / Font.atlas_width,
            .v0 = @as(f32, @floatFromInt(pen_y)) / Font.atlas_height,
            .u1 = @as(f32, @floatFromInt(pen_x + glyph_w)) / Font.atlas_width,
            .v1 = @as(f32, @floatFromInt(pen_y + glyph_h)) / Font.atlas_height,
            .xoff = @floatFromInt(xoff),
            .yoff = @floatFromInt(yoff),
            .width = @floatFromInt(glyph_w),
            .height = @floatFromInt(glyph_h),
            .xadvance = @as(f32, @floatFromInt(advance)) * scale,
        };

        if (glyph_w > 0) {
            pen_x += glyph_w + 1;
            row_height = @max(row_height, glyph_h);
        }
    }

    return coverage;
}
