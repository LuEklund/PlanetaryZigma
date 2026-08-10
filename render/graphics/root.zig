//! Pieces the game assembles a frame out of. Nothing here holds the .so — the caller opens
//! `render`'s Table itself and decides what to feed it, because client and server want
//! different frames.
//!
//! Not named after the renderer: that is the contract plus the backend, and nothing in it
//! knows this exists. The file readers live in `assets/` beside this, so `assets.Model` is a
//! parsed glTF and `graphics.Assets` is the set this game loaded out of one.

/// The game's files and what they parsed into. A struct that owns state, like `Animator` —
/// the renderer is a parameter to its calls, never a field.
pub const Assets = @import("Assets.zig");
pub const Rig = @import("Rig.zig");

pub const Animator = @import("Animator.zig");
/// A free list with spawn/keepAlive/timeout rules — behaviour, so it is a system and not
/// part of the contract. The contract only carries the rows it produces.
pub const Emitter = @import("Emitter.zig");
