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

pub const DrawList = @import("DrawList.zig");

pub const Renderer = struct {
    userdata: *anyopaque,
    /// Points AT the loader's table, never a copy of it: a hot swap rewrites that table in
    /// place, and a copy would go on calling the closed image.
    vtable: *const VTable,

    pub const InitOptions = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        window: *Window,
    };

    /// Field names ARE the exported symbol names — HotLib resolves by field. render.so is
    /// dlopened RTLD_LOCAL, so short names here do not enter the global namespace.
    pub const VTable = struct {
        init: *const fn (options: *const InitOptions) callconv(.c) ?*anyopaque,
        deinit: *const fn (*anyopaque) callconv(.c) void,
        update: *const fn (*anyopaque, list: *DrawList) callconv(.c) void,
        reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,

        /// `kind` is a Shader.Kind ordinal — enums are not allowed across a C boundary.
        /// Kind IS the handle: the render passes bind shaders by kind, so nothing comes back.
        uploadShader: *const fn (*anyopaque, kind: u32, spirv: [*]align(4) const u8, len: usize) callconv(.c) void,
        /// Slot rides inside the upload: file textures are a comptime set, so the producer
        /// already names them and `Ui` reads the same numbers.
        uploadTexture: *const fn (*anyopaque, upload: *const DrawList.TextureUpload) callconv(.c) void,

        /// Runtime-created, so the backend names them. `old` is freed first; pass `.none`
        /// on a first load. Both return 0 / `.none` on failure.
        uploadMesh: *const fn (*anyopaque, old: MeshHandle, upload: *const MeshUpload) callconv(.c) MeshHandle,
        uploadImage: *const fn (*anyopaque, upload: *const ImageUpload) callconv(.c) u32,
        freeMesh: *const fn (*anyopaque, handle: MeshHandle) callconv(.c) void,
        freeImage: *const fn (*anyopaque, slot: u32) callconv(.c) void,
    };
};

/// What the backend hands back for an uploaded mesh. Its bits are the backend's business.
pub const MeshHandle = enum(usize) {
    none,
    _,
};

/// One mesh, one upload. Geometry arrives as bytes; `skinned` says which layout to read
/// them as. Surfaces carry absolute texture slots, already resolved by the producer.
pub const MeshUpload = struct {
    name: []const u8,
    vertices: []const u8,
    skinned: bool,
    indices: []const u32,
    surfaces: []const SurfaceUpload,
};

pub const SurfaceUpload = struct {
    index_start: u32,
    index_count: u32,
    texture_slot: u32,
};

/// An image with no name of its own — a glTF embedded texture. The sampler is described
/// inline; there is no separate sampler table to index into.
pub const ImageUpload = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
    /// Single-channel coverage rather than RGBA — a font atlas.
    r8: bool,
    mips: bool,
    mag_linear: bool,
    min_linear: bool,
};
