//! Bakes font atlases on THIS side of the boundary. Twin of ShaderSource/TextureSource.
//!
//! Glyph metrics AND the atlas slot land in the caller's `fonts` array: the slot is just
//! the return value of uploadFont, so nothing of ours crosses into render.so and stays.

const FontSource = @This();

const std = @import("std");
const shared = @import("shared");
const stbTruetype = @import("stb_truetype");
const Font = @import("shared").Font;
const AssetServer = @import("assets").AssetServer;
const contract = @import("contract");

const Loader = AssetServer.Loader;
/// The loaded renderer library: its table and the state block it goes with.
const RenderLib = shared.HotLib(contract.Api, *anyopaque, "reload");


gpa: std.mem.Allocator,
fonts: []Font,
coverage: [Font.count]?[]u8,
/// Read only inside `load`, which the owner runs after the renderer exists.
renderer: *const RenderLib,
interface: Loader,

pub fn init(
    self: *FontSource,
    gpa: std.mem.Allocator,
    asset_server: *AssetServer,
    fonts: []Font,
    renderer: *const RenderLib,
) !void {
    std.debug.assert(fonts.len == Font.files.len);
    @memset(fonts, .empty);

    self.* = .{
        .gpa = gpa,
        .fonts = fonts,
        .coverage = @splat(null),
        .renderer = renderer,
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

pub fn deinit(self: *FontSource) void {
    for (&self.coverage) |*slot| if (slot.*) |bytes| self.gpa.free(bytes);
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *FontSource = @fieldParentPtr("interface", loader);
    const file = try err_file;

    const coverage = try bake(&self.fonts[index], self.gpa, loader.io, file);
    errdefer self.gpa.free(coverage);

    if (self.coverage[index]) |old| self.gpa.free(old);
    self.coverage[index] = coverage;

    if (self.fonts[index].atlas_texture_index != 0) {
        self.renderer.api.freeImage(self.renderer.handle, self.fonts[index].atlas_texture_index);
    }
    self.fonts[index].atlas_texture_index = self.renderer.api.uploadImage(self.renderer.handle, &.{
        .width = Font.atlas_width,
        .height = Font.atlas_height,
        .pixels = coverage,
        .r8 = true,
        .mips = false,
        .mag_linear = true,
        .min_linear = true,
    });
}

fn unload(loader: *Loader, index: usize) void {
    _ = loader;
    _ = index;
    // Coverage stays owned until the next load replaces it; the atlas image and its slot
    // are the backend's to release when it applies the next upload.
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
            for (0..glyph_h) |y| {
                const src = sdf[y * glyph_w ..][0..glyph_w];
                const dst = coverage[(pen_y + y) * Font.atlas_width + pen_x ..][0..glyph_w];
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
