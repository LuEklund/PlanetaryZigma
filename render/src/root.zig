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

pub const AssetServer = @import("AssetServer.zig");
pub const DrawList = @import("DrawList.zig");
pub const ModelTable = @import("asset/ModelTable.zig");
pub const Renderer = @import("Renderer.zig");

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    asset_server: *AssetServer,
    fonts: *[Font.count]Font,
    models: *ModelTable,
    window: *Window,
};

pub const Table = struct {
    renderInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    renderDeinit: *const fn (*anyopaque) callconv(.c) void,
    renderUpdate: *const fn (*anyopaque, list: *DrawList) callconv(.c) void,
    renderReload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
};
