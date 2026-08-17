const std = @import("std");

pub const log = @import("log.zig");
pub const DrawList = @import("DrawList.zig");

pub const Shader = @import("Shader.zig");

pub const ParticleEffects = @import("ParticleEffects.zig");
pub const Placement = ParticleEffects.Placement;
pub const Motion = ParticleEffects.Motion;
pub const ParticleEffect = ParticleEffects.ParticleEffect;
pub const EffectParams = ParticleEffects.EffectParams;
pub const instancesPerEmitter = ParticleEffects.instancesPerEmitter;
pub const effect_params = ParticleEffects.effect_params;

pub const InitOptions = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *anyopaque,
};

/// Field names ARE the exported symbol names — HotLib resolves by field. render.so is
/// dlopened RTLD_LOCAL, so short names here do not enter the global namespace.
pub const Api = struct {
    init: *const fn (options: *const InitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (*anyopaque) callconv(.c) void,
    update: *const fn (*anyopaque, list: *DrawList) callconv(.c) void,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,

    uploadMesh: *const fn (*anyopaque, old: MeshHandle, upload: *const MeshUpload) callconv(.c) MeshHandle,
    freeMesh: *const fn (*anyopaque, handle: MeshHandle) callconv(.c) void,

    uploadImage: *const fn (*anyopaque, upload: *const ImageUpload) callconv(.c) TextureHandle,
    uploadSkybox: *const fn (*anyopaque, upload: *const SkyboxUpload) callconv(.c) void,
    uploadShader: *const fn (*anyopaque, kind: u32, spirv: [*]align(4) const u8, len: usize) callconv(.c) void,
    freeImage: *const fn (*anyopaque, texture: TextureHandle) callconv(.c) void,
};

pub const TextureHandle = enum(u32) {
    blank,
    missing,
    _,
};

pub const MeshHandle = enum(usize) {
    none,
    _,
};

pub const MeshUpload = struct {
    name: []const u8,
    vertices: []const u8,
    skinned: bool,
    indices: []const u32,
    surfaces: []const SurfaceUpload,
};

pub const SkyboxUpload = struct {
    size: u32,
    faces: [6][]const u8,
};

pub const ImageUpload = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
    r8: bool,
    mips: bool,
    mag_linear: bool,
    min_linear: bool,
};

pub const SurfaceUpload = struct {
    index_start: u32,
    index_count: u32,
    texture: TextureHandle,
    transparent: bool,
};
