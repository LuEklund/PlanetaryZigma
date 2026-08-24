const Assets = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("renderer_contract");

pub const Shaders = @import("Shaders.zig");
pub const Textures = @import("Textures.zig");
pub const Skybox = @import("Skybox.zig");
pub const Fonts = @import("Fonts.zig");
pub const Models = @import("Models.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

root: [:0]const u8,
shaders: Shaders,
textures: Textures,
skybox: Skybox,
fonts: Fonts,
models: Models,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Assets {
    var self: Assets = .{
        .root = try @import("assets/root.zig").findRoot(io),
        .fonts = try .init(gpa, io),
        .shaders = try .init(gpa, io),
        .textures = try .init(gpa, io),
        .skybox = try .init(io),
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

pub fn update(self: *Assets, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    try self.shaders.update(gpa, io, renderer);
    try self.textures.update(gpa, io, renderer);
    try self.skybox.update(gpa, io, renderer);
    try self.fonts.update(gpa, io, renderer);
    try self.models.update(gpa, io, renderer);
}
