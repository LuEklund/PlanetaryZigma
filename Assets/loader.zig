//! Stage two: a file changed, turn it into data. One entry point per kind — the heavy
//! lifting lives in `loader/`, since a glb and a png share nothing but a filename.
//!
//! Nothing here knows where the data goes.

pub const shader = @import("loader/shader.zig").read;

pub const texture = @import("loader/texture.zig").decode;
pub const Decoded = @import("loader/texture.zig").Decoded;

pub const font = @import("loader/font.zig").bake;

pub const model = @import("loader/model.zig").parse;
pub const Parsed = @import("loader/model.zig").Parsed;
