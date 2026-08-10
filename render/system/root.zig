//! Pieces the game assembles a frame out of. Nothing here holds the .so — the caller opens
//! `render`'s Table itself and decides what to feed it, because client and server want
//! different frames.
//!
//! Kept out of the `render` module deliberately. That one is the contract plus the backend;
//! anything that holds per-frame or per-entity state lives here, where the game can own it.

/// The game's files and what they parsed into. A struct that owns state, like `Animator` —
/// the renderer is a parameter to its calls, never a field.
pub const Assets = @import("Assets.zig");
/// What the loader hands the animator.
pub const ModelTable = @import("ModelTable.zig");
pub const Rig = @import("Rig.zig");

pub const Animator = @import("Animator.zig");
/// A free list with spawn/keepAlive/timeout rules — behaviour, so it is a system and not
/// part of the contract. The contract only carries the rows it produces.
pub const Emitter = @import("Emitter.zig");
