//! Everything the game has on disk, one struct per kind. Each owns its watcher, its rows and
//! its named lookups, and each knows how to push what changed at the renderer.
//!
//! The renderer arrives as a parameter and is never stored, so nothing here holds a pointer
//! into a library that can be swapped underneath it. `assets` knows nothing about a renderer
//! and the renderer knows nothing about a file — this is the one place that knows both.

const Assets = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");

pub const Shaders = @import("Shaders.zig");
pub const Textures = @import("Textures.zig");
pub const Skybox = @import("Skybox.zig");
pub const Fonts = @import("Fonts.zig");
pub const Models = @import("Models.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

shaders: Shaders,
textures: Textures,
skybox: Skybox,
fonts: Fonts,
models: Models,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Assets {
    var self: Assets = .{
        .shaders = try .init(gpa, io),
        .textures = try .init(gpa, io),
        .skybox = try .init(io),
        .fonts = try .init(gpa, io),
        .models = try .init(gpa, io),
    };
    errdefer self.deinit(gpa, io);
    return self;
}

pub fn deinit(self: *Assets, gpa: std.mem.Allocator, io: std.Io) void {
    self.shaders.deinit(gpa, io);
    self.textures.deinit(gpa, io);
    self.skybox.deinit(io);
    self.fonts.deinit(gpa, io);
    self.models.deinit(gpa, io);
}

/// Everything that changed on disk, in the order a frame needs it: nothing draws without
/// shaders, and a mesh surface names a texture slot.
pub fn update(self: *Assets, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    try self.shaders.update(gpa, io, renderer);
    try self.textures.update(gpa, io, renderer);
    try self.skybox.update(gpa, io, renderer);
    try self.fonts.update(gpa, io, renderer);
    try self.models.update(gpa, io, renderer);
}
