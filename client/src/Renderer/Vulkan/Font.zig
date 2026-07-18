const Font = @This();

const std = @import("std");
const c = @import("vulkan");
const Image = @import("Image.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const stbTruetype = @import("stb_truetype");
const check = @import("utils.zig").check;

image: Image,
sampler: c.VkSampler,
atlas_texture: Image.Handle,

device: Device,
vma: Vma,
glyphs: [96]Glyph,
size: f32,

pub const Glyph = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    xoff: f32,
    yoff: f32,
    width: f32,
    heigth: f32,
    xadvance: f32,
};

pub fn init(vma: Vma, device: Device) Font {
    return .{
        .device = device,
        .vma = vma,
        .image = undefined,
        .sampler = null,
        .atlas_texture = undefined,
        .glyphs = undefined,
        .size = 32,
    };
}

pub fn load(self: *Font, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);
    std.log.debug("font file size: {d}", .{content.len});

    const atlas_w: usize = 512;
    const atlas_h: usize = 512;

    const coverage = try gpa.alloc(u8, atlas_w * atlas_h);
    defer gpa.free(coverage);
    @memset(coverage, 0);

    const padding: c_int = 5;
    const on_edge: u8 = 128;
    const pixel_dist_scale: f32 = @as(f32, on_edge) / @as(f32, padding);

    var info: stbTruetype.stbtt_fontinfo = undefined;
    _ = stbTruetype.stbtt_InitFont(&info, content.ptr, 0);
    const scale = stbTruetype.stbtt_ScaleForPixelHeight(&info, self.size);

    var pen_x: usize = 1;
    var pen_y: usize = 1;
    var row_heigth: usize = 0;
    for (&self.glyphs, 0..) |*glyph, i| {
        const codepoint: c_int = @intCast(32 + i);
        var advance: c_int = 0;
        var left_bearing: c_int = 0;
        stbTruetype.stbtt_GetCodepointHMetrics(&info, codepoint, &advance, &left_bearing);

        var width: c_int = 0;
        var heigth: c_int = 0;
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
            &heigth,
            &xoff,
            &yoff,
        );
        defer if (sdf != null) stbTruetype.stbtt_FreeSDF(sdf, null);

        const glyph_w: usize = @intCast(width);
        const glyph_h: usize = @intCast(heigth);
        if (sdf != null and glyph_w > 0) {
            if (pen_x + glyph_w + 1 > atlas_w) {
                pen_x = 1;
                pen_y += row_heigth + 1;
                row_heigth = 0;
            }
            for (0..glyph_h) |row| {
                const src = sdf[row * glyph_w ..][0..glyph_w];
                const dst = coverage[(pen_y + row) * atlas_w + pen_x ..][0..glyph_w];
                @memcpy(dst, src);
            }
        }

        glyph.* = .{
            .u0 = @as(f32, @floatFromInt(pen_x)) / atlas_w,
            .v0 = @as(f32, @floatFromInt(pen_y)) / atlas_h,
            .u1 = @as(f32, @floatFromInt(pen_x + glyph_w)) / atlas_w,
            .v1 = @as(f32, @floatFromInt(pen_y + glyph_h)) / atlas_h,
            .xoff = @floatFromInt(xoff),
            .yoff = @floatFromInt(yoff),
            .width = @floatFromInt(glyph_w),
            .heigth = @floatFromInt(glyph_h),
            .xadvance = @as(f32, @floatFromInt(advance)) * scale,
        };

        if (glyph_w > 0) {
            pen_x += glyph_w + 1;
            row_heigth = @max(row_heigth, glyph_h);
        }
    }

    self.image = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8_UNORM,
        .{ .width = @intCast(atlas_w), .height = @intCast(atlas_h), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    try self.image.uploadDataToImage(self.vma, self.device, coverage.ptr, 1, 0);

    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    try check(c.vkCreateSampler(self.device.handle, &sampler_info, null, &self.sampler));
}

pub fn deinit(self: *Font, device: Device) void {
    c.vkDestroySampler(device.handle, self.sampler, null);
}
