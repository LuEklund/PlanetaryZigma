//! The renderer ABI: the module every consumer imports, and all they may import.
//!
//! It depends on numz and nothing here may reach an implementation. The
//! moment it does, every backend edit recompiles system_client.so and the hot-reload
//! boundary is gone. Guard: `touch render/vulkan/internal/Vulkan.zig`, rebuild, and
//! `zig-out/lib/libsystem_client.so` must be byte-identical.
//!
//! See implementation_ideas/systems-as-libraries.md § LIBRARY-SHAPE CONVENTION.

const std = @import("std");

pub const log = @import("log.zig");
pub const DrawList = @import("DrawList.zig");

/// Slots the backend owns and writes itself. Everything above this number is a texture the
/// producer uploaded, named in whatever order it likes.
pub const reserved_textures: u32 = 3;
pub const blank_texture: u32 = 0;
pub const missing_texture: u32 = 1;
pub const highlight_mask_texture: u32 = 2;
/// Shader kinds, descriptor sets and push-constant layouts: all four are renderer facts,
/// so they live with the renderer rather than in the game's wire contract.
pub const Shader = @import("Shader.zig");

pub const InitOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The platform window, opaque here on purpose: what a window is belongs to the
    /// platform layer and the implementation, not to the ABI between them.
    window: *anyopaque,
};

/// Field names ARE the exported symbol names — HotLib resolves by field. render.so is
/// dlopened RTLD_LOCAL, so short names here do not enter the global namespace.
pub const Api = struct {
    init: *const fn (options: *const InitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (*anyopaque) callconv(.c) void,
    update: *const fn (*anyopaque, list: *DrawList) callconv(.c) void,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,

    /// Runtime-created, so the backend names them. `old` is freed first; pass `.none`
    /// on a first load. Both return 0 / `.none` on failure.
    uploadMesh: *const fn (*anyopaque, old: MeshHandle, upload: *const MeshUpload) callconv(.c) MeshHandle,
    freeMesh: *const fn (*anyopaque, handle: MeshHandle) callconv(.c) void,

    /// Pixels, not files. A model and a font are the caller's words for a file it parsed;
    /// what arrives here is an image and a mesh, which is all a renderer has a name for.
    ///
    /// Nothing outside names a texture — the backend does, and hands the handle back. The
    /// three reserved ones are the only fixed numbers, and it writes those itself.
    ///
    /// `old` is the handle from the last upload of the same image; passing it back rewrites
    /// that slot instead of leaking it. Any reserved handle means "no slot yet" and gets a
    /// fresh one — those three are shared and never written by a caller.
    uploadImage: *const fn (*anyopaque, old: u32, upload: *const ImageUpload) callconv(.c) u32,
    /// Its own call because it is its own thing: six faces, one of them in the whole scene,
    /// and it goes to the sky rather than into the table. Nothing comes back to name.
    uploadSkybox: *const fn (*anyopaque, upload: *const SkyboxUpload) callconv(.c) void,
    /// `kind` is a Shader.Kind ordinal — enums are not allowed across a C boundary. Kind IS
    /// the handle: the render passes bind shaders by kind, so nothing comes back.
    uploadShader: *const fn (*anyopaque, kind: u32, spirv: [*]align(4) const u8, len: usize) callconv(.c) void,
    freeImage: *const fn (*anyopaque, slot: u32) callconv(.c) void,
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

/// The sky, as six square faces in Vulkan order. Always mipless and always linear — there
/// is one of these and it fills the horizon.
pub const SkyboxUpload = struct {
    size: u32,
    faces: [6][]const u8,
};

/// One 2D image. The sampler is described inline; there is no separate sampler table to
/// index into.
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

pub const SurfaceUpload = struct {
    index_start: u32,
    index_count: u32,
    texture_slot: u32,
};
