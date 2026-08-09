//! The client-side render system: it owns the frame packet, the animator, the asset sources
//! and the handle to render.so. None of that belongs to the renderer — the renderer is the
//! `.so` behind `render`'s Table, and this is the thing that feeds it.
//!
//! Kept out of `render/src/` deliberately. That package is the contract plus the backend;
//! anything that holds per-frame or per-entity state lives here, where the game can own it.

pub const Renderer = @import("Renderer.zig");
pub const Animator = @import("Animator.zig");
