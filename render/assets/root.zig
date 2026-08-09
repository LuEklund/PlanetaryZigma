//! The asset system's face. Nothing outside this folder may reach into it — go through here,
//! the same way `../root.zig` is the face of the render module.
//!
//! Deliberately free of any render type: this is parsed/decoded asset data and the file
//! watcher, nothing more. That is what lets it be its own module, imported directly by the
//! game rather than through the renderer.

pub const AssetServer = @import("AssetServer.zig");
pub const Bitmap = @import("Bitmap.zig");
pub const gltf = @import("gltf.zig");
pub const Model = @import("Model.zig");
pub const ModelTable = @import("ModelTable.zig");
pub const Node = @import("Node.zig");
pub const AnimationClip = @import("AnimationClip.zig");
pub const box = @import("box.zig");
