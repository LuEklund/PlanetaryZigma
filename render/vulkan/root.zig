const std = @import("std");
const Vulkan = @import("internal/Vulkan.zig");
const contract = @import("renderer_contract");
const DrawList = contract.DrawList;

// The Renderer struct lives in the contract, not here: consumers must reach it without
// reaching this file, or importing it drags the whole backend into their compilation.
const InitOptions = contract.InitOptions;

// Each image carries its own copy of these globals, so this one needs its own wiring.
pub const std_options: std.Options = .{ .logFn = contract.log.logFn };

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    vulkan: *Vulkan,
};

// Root-module test, NOT output_mode == .Lib: system_client.so is also a Lib, and that
// guard made it compile and export the entire Vulkan backend it only wanted types from.
comptime {
    if (@import("root") == @This()) _ = ffi;
}

pub const ffi = struct {
    pub export fn init(data: *const InitOptions) ?*anyopaque {
        contract.log.io = data.io;
        std.log.info("render init", .{});
        const context = data.gpa.create(Context) catch return null;
        context.* = .{
            .gpa = data.gpa,
            .io = data.io,
            .vulkan = Vulkan.init(data) catch |err| {
                std.log.err("render init: {s}", .{@errorName(err)});
                data.gpa.destroy(context);
                return null;
            },
        };
        return context;
    }

    pub export fn deinit(handle: *anyopaque) void {
        std.log.info("render deinit", .{});
        const context: *Context = @ptrCast(@alignCast(handle));
        const gpa = context.gpa;
        context.vulkan.deinit(gpa);
        gpa.destroy(context);
    }

    pub export fn reload(handle: *anyopaque, pre_reload: bool) void {
        if (pre_reload) return;
        const context: *Context = @ptrCast(@alignCast(handle));
        contract.log.io = context.io;
        context.vulkan.rebindProcs();
    }

    pub export fn uploadImage(handle: *anyopaque, upload: *const contract.ImageUpload) contract.TextureHandle {
        const context: *Context = @ptrCast(@alignCast(handle));
        return context.vulkan.resources.uploadImage(upload) catch |err| {
            std.log.err("upload image: {s}", .{@errorName(err)});
            return .missing;
        };
    }

    pub export fn uploadSkybox(handle: *anyopaque, upload: *const contract.SkyboxUpload) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.uploadSkybox(upload, context.vulkan.current_frame_inflight) catch |err| {
            std.log.err("upload skybox: {s}", .{@errorName(err)});
        };
    }

    pub export fn uploadMesh(handle: *anyopaque, old: contract.MeshHandle, upload: *const contract.MeshUpload) contract.MeshHandle {
        const context: *Context = @ptrCast(@alignCast(handle));
        return context.vulkan.resources.uploadMesh(old, context.vulkan.current_frame_inflight, upload) catch |err| {
            std.log.err("upload mesh {s}: {s}", .{ upload.name, @errorName(err) });
            return .none;
        };
    }

    pub export fn freeMesh(handle: *anyopaque, mesh: contract.MeshHandle) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.freeMesh(mesh, context.vulkan.current_frame_inflight);
    }

    pub export fn freeImage(handle: *anyopaque, texture: contract.TextureHandle) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.freeTexture(texture, context.vulkan.current_frame_inflight);
    }

    pub export fn uploadShader(handle: *anyopaque, kind: u32, spirv: [*]align(4) const u8, len: usize) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.shaders.apply(@enumFromInt(kind), spirv[0..len]) catch |err| {
            std.log.err("upload shader {d}: {t}", .{ kind, err });
        };
    }

    pub export fn update(handle: *anyopaque, list: *DrawList) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.update(list) catch |err| {
            std.log.err("render update: {s}", .{@errorName(err)});
        };
    }
};
