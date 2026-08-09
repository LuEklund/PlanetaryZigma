const std = @import("std");
const Vulkan = @import("internal/Vulkan.zig");
const contract = @import("contract");
const DrawList = contract.DrawList;
const render = @import("contract");

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

    // A freshly dlopened render.so has its OWN procs.instance/device globals, still
    // undefined — rebinding them is what makes a render swap work at all.
    //
    // Nothing else needs re-registering: every loader AssetServer holds now lives above the
    // boundary; shaders, fonts and textures upload through the vtable, models via the packet.
    pub export fn reload(handle: *anyopaque, pre_reload: bool) void {
        if (pre_reload) return;
        const context: *Context = @ptrCast(@alignCast(handle));
        contract.log.io = context.io;
        context.vulkan.rebindProcs();
    }

    pub export fn uploadShader(handle: *anyopaque, kind: u32, spirv: [*]align(4) const u8, len: usize) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        const shader_kind: render.Shader.Kind = @enumFromInt(kind);
        context.vulkan.resources.shaders.apply(shader_kind, spirv[0..len]) catch |err| {
            std.log.err("upload shader {t}: {s}", .{ shader_kind, @errorName(err) });
        };
    }

    pub export fn uploadTexture(handle: *anyopaque, upload: *const DrawList.TextureUpload) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        _ = context.vulkan.resources.uploadTexture(.{
            .slot = upload.slot,
            .width = upload.width,
            .height = upload.height,
            .faces = upload.faces,
            .r8 = false,
            .mips = false,
            .mag_linear = true,
            .min_linear = true,
        }) catch |err| {
            std.log.err("upload texture slot {d}: {s}", .{ upload.slot, @errorName(err) });
        };
    }

    pub export fn uploadMesh(handle: *anyopaque, old: contract.MeshHandle, upload: *const contract.MeshUpload) contract.MeshHandle {
        const context: *Context = @ptrCast(@alignCast(handle));
        return context.vulkan.resources.uploadMesh(old, context.vulkan.current_frame_inflight, upload) catch |err| {
            std.log.err("upload mesh {s}: {s}", .{ upload.name, @errorName(err) });
            return .none;
        };
    }

    pub export fn uploadImage(handle: *anyopaque, upload: *const contract.ImageUpload) u32 {
        const context: *Context = @ptrCast(@alignCast(handle));
        return context.vulkan.resources.uploadTexture(.{
            .slot = null,
            .width = upload.width,
            .height = upload.height,
            .faces = &.{upload.pixels},
            .r8 = upload.r8,
            .mips = upload.mips,
            .mag_linear = upload.mag_linear,
            .min_linear = upload.min_linear,
        }) catch |err| {
            std.log.err("upload image: {s}", .{@errorName(err)});
            return 0;
        };
    }

    pub export fn freeMesh(handle: *anyopaque, mesh: contract.MeshHandle) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.freeMesh(mesh, context.vulkan.current_frame_inflight);
    }

    pub export fn freeImage(handle: *anyopaque, slot: u32) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resources.freeTexture(slot);
    }

    pub export fn update(handle: *anyopaque, list: *DrawList) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.update(list) catch |err| {
            std.log.err("render update: {s}", .{@errorName(err)});
        };
    }
};
