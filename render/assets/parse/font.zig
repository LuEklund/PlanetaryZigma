const std = @import("std");
const stbTruetype = @import("stb_truetype");
const Font = @import("shared").Font;

/// Bakes an SDF atlas and fills in `self`'s glyph metrics. The coverage bitmap is returned
/// for the caller to do what it likes with.
pub fn bake(self: *Font, gpa: std.mem.Allocator, content: []const u8) ![]u8 {

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
        const sdf = stbTruetype.stbtt_GetCodepointSDF(&info, scale, codepoint, padding, on_edge, pixel_dist_scale, &width, &height, &xoff, &yoff);
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
