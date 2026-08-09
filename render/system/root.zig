//! Pieces the game assembles a frame out of. Nothing here holds the .so — the caller opens
//! `render`'s Table itself and decides what to feed it, because client and server want
//! different frames.
//!
//! Kept out of the `render` module deliberately. That one is the contract plus the backend;
//! anything that holds per-frame or per-entity state lives here, where the game can own it.

pub const Animator = @import("Animator.zig");
pub const Assets = @import("Assets.zig");
