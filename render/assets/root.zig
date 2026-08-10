//! Everything between a file on disk and data in memory: which files changed, the bytes,
//! the parse.
//!
//! Nothing in here knows what the data is FOR. No renderer type appears anywhere in it, and
//! `Watcher` does not even know what a texture is — it watches a directory.

/// One directory's worth of files. One instance per kind, so nothing switches on a tag.
pub const Watcher = @import("Watcher.zig");
pub const openDir = @import("dir.zig").open;

pub const Bitmap = @import("types/Bitmap.zig");
pub const gltf = @import("types/gltf.zig");
pub const Model = @import("types/Model.zig");
pub const Node = @import("types/Node.zig");
pub const AnimationClip = @import("types/AnimationClip.zig");
pub const box = @import("types/box.zig");

/// Bytes off the disk — one function, every kind.
pub const read = @import("read.zig").file;
/// Bytes into data — one entry point per kind.
pub const parse = @import("parse.zig");
