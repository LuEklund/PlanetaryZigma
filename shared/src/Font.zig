const Font = @This();

pub const files: []const []const u8 = &.{"Roboto-Regular.ttf"};
pub const count: usize = files.len;

pub const atlas_width: usize = 512;
pub const atlas_height: usize = 512;

glyphs: [96]Glyph,
size: f32,
atlas_texture_index: u32,

pub const Glyph = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    xoff: f32,
    yoff: f32,
    width: f32,
    height: f32,
    xadvance: f32,
};

pub const empty: Font = .{
    .glyphs = undefined,
    .size = 32,
    .atlas_texture_index = 0,
};
