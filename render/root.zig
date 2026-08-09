//! The render contract — this is the module consumers import, and all they may import.
//!
//! It must NEVER reach the backend. The moment anything here transitively imports
//! `backend/Vulkan.zig`, every render edit recompiles system_client.so again and the
//! whole boundary is gone. Guard: `touch render/src/backend/Vulkan.zig`, rebuild, and
//! `zig-out/lib/libsystem_client.so` must be byte-identical.
//!
//! See implementation_ideas/systems-as-libraries.md § LIBRARY-SHAPE CONVENTION.

const std = @import("std");
const Window = @import("Window");
const Font = @import("shared").Font;

pub const DrawList = @import("DrawList.zig");

/// Upper bound on distinct model files. Comptime like every other bound in the codebase
/// (max_entities, max_ui_quads, max_draw_meshes) so the backend allocates nothing for it —
/// the array sits inside the block renderInit already made. Overflow is a loud assert, not
/// a resize; make it dynamic only when a real workload needs it.
pub const max_models: u32 = 64;

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fonts: *[Font.count]Font,
    window: *Window,
};

pub const VTable = struct {
    renderInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    renderDeinit: *const fn (*anyopaque) callconv(.c) void,
    renderUpdate: *const fn (*anyopaque, list: *DrawList) callconv(.c) void,
    renderReload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
};
