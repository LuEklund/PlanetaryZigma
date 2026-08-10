//! Stage three: bytes in, data out. One file per kind, because a glb and a png share
//! nothing but having been read off a disk.
//!
//! Shaders have no entry here — SPIR-V is already the data.

pub const texture = @import("parse/texture.zig").decode;
pub const Decoded = @import("parse/texture.zig").Decoded;

pub const font = @import("parse/font.zig").bake;

pub const model = @import("parse/model.zig").glb;
pub const Parsed = @import("parse/model.zig").Parsed;
