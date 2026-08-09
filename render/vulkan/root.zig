const std = @import("std");
const Vulkan = @import("internal/Vulkan.zig");
const contract = @import("render");
const DrawList = contract.DrawList;
const shared = @import("shared");

// Table/Data live in the contract, not here: consumers must reach them without reaching
// this file, or importing them drags the whole backend into their compilation.
pub const Data = contract.Data;
pub const Table = contract.Table;

// Each .so carries its own copy of shared's globals, so this one needs its own wiring.
pub const std_options: std.Options = .{ .logFn = shared.logFn };

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
    pub export fn renderInit(data: *const Data) ?*anyopaque {
        shared.log_io = data.io;
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

    pub export fn renderDeinit(handle: *anyopaque) void {
        std.log.info("render deinit", .{});
        const context: *Context = @ptrCast(@alignCast(handle));
        const gpa = context.gpa;
        context.vulkan.deinit(gpa);
        gpa.destroy(context);
    }

    // A freshly dlopened render.so has its OWN procs.instance/device globals, still
    // undefined — rebinding them is what makes a render swap work at all.
    //
    // ponytail: Model/Texture/Font loaders are NOT re-registered, so after a swap they keep
    // running the previous image's code. Symptom: an edit to those *Loader.zig appears to do
    // nothing. Fix is a restart, or finish the asset flip for them.
    // Shaders are already exempt: ShaderSource lives above the boundary, so the pointers
    // AssetServer holds for it survive a swap, and bytes arrive via DrawList.shader_uploads.
    pub export fn renderReload(handle: *anyopaque, pre_reload: bool) void {
        if (pre_reload) return;
        const context: *Context = @ptrCast(@alignCast(handle));
        shared.log_io = context.io;
        context.vulkan.rebindProcs();
    }

    pub export fn renderUpdate(handle: *anyopaque, list: *DrawList) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.update(list) catch |err| {
            std.log.err("render update: {s}", .{@errorName(err)});
        };
    }
};
