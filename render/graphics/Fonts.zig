//! The font files, and the glyph metrics they baked into. Only the atlas goes to the GPU —
//! everything the UI measures with stays here.

const Fonts = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const assets = @import("assets/root.zig");
const stbTruetype = @import("stb_truetype");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
    font: shared.Font,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Fonts {
    const root = try assets.openDir(io);
    defer root.close(io);
    var self: Fonts = .{ .dir = try root.openDir(io, "fonts", .{}), .entries = .empty };
    errdefer self.deinit(gpa, io);
    for (shared.Font.files) |path| _ = try self.add(gpa, path);
    return self;
}

pub fn deinit(self: *Fonts, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    self.entries.deinit(gpa);
}

pub fn add(self: *Fonts, gpa: std.mem.Allocator, path: []const u8) !u32 {
    const handle: u32 = @intCast(self.entries.items.len);
    try self.entries.append(gpa, .{ .path = path, .mtime = .zero, .font = .empty });
    return handle;
}

pub fn get(self: *const Fonts, handle: u32) *const shared.Font {
    return &self.entries.items[handle].font;
}

/// The one everything measures against until a caller has a reason to name another.
pub fn default(self: *const Fonts) *const shared.Font {
    return self.get(0);
}

pub fn update(self: *Fonts, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items) |*entry| {
        if (!assets.changed(io, self.dir, entry.path, &entry.mtime)) continue;
        const bytes = try assets.read(gpa, io, self.dir, entry.path);
        defer gpa.free(bytes);

        const coverage = try parse(&entry.font, gpa, bytes);
        defer gpa.free(coverage);

        // Passing the old atlas back rewrites that slot, so there is nothing to free.
        entry.font.atlas_texture_index = renderer.api.uploadImage(renderer.handle, entry.font.atlas_texture_index, &.{
            .width = shared.Font.atlas_width,
            .height = shared.Font.atlas_height,
            .pixels = coverage,
            .r8 = true,
            .mips = false,
            .mag_linear = true,
            .min_linear = true,
        });
    }
}

/// Bakes an SDF atlas and fills in `self`'s glyph metrics. The coverage bitmap is returned
/// for the caller to do what it likes with.
fn parse(self: *shared.Font, gpa: std.mem.Allocator, content: []const u8) ![]u8 {
    const coverage = try gpa.alloc(u8, shared.Font.atlas_width * shared.Font.atlas_height);
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
            if (pen_x + glyph_w + 1 > shared.Font.atlas_width) {
                pen_x = 1;
                pen_y += row_height + 1;
                row_height = 0;
            }
            for (0..glyph_h) |y| {
                const src = sdf[y * glyph_w ..][0..glyph_w];
                const dst = coverage[(pen_y + y) * shared.Font.atlas_width + pen_x ..][0..glyph_w];
                @memcpy(dst, src);
            }
        }

        glyph.* = .{
            .u0 = @as(f32, @floatFromInt(pen_x)) / shared.Font.atlas_width,
            .v0 = @as(f32, @floatFromInt(pen_y)) / shared.Font.atlas_height,
            .u1 = @as(f32, @floatFromInt(pen_x + glyph_w)) / shared.Font.atlas_width,
            .v1 = @as(f32, @floatFromInt(pen_y + glyph_h)) / shared.Font.atlas_height,
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
