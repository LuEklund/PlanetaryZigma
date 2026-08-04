const std = @import("std");
const Window = @import("Window");
const Vulkan = @import("Renderer/Vulkan.zig");
const DrawList = @import("DrawList.zig");
const AssetServer = @import("AssetServer.zig");
const Font = @import("asset/Font.zig");
pub const ModelTable = @import("asset/ModelTable.zig");
const shared = @import("shared");

// Each .so carries its own copy of shared's globals, so this one needs its own log
// wiring exactly like System.init does — otherwise the first log here reads a null io.
pub const std_options: std.Options = .{ .logFn = shared.logFn };

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    asset_server: *AssetServer,
    /// Caller-owned, `Font.count` long. Ui reads glyph metrics through it, so the
    /// storage lives on the exe side rather than being lent back out of render.so.
    fonts: []Font,
    models: *ModelTable,
    texture_slots: []u32,
    window: *Window,
};

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    vulkan: *Vulkan,
};

pub const Table = struct {
    renderInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    renderDeinit: *const fn (*anyopaque) callconv(.c) void,
    renderUpdate: *const fn (*anyopaque, packet: *DrawList) callconv(.c) void,
    renderReload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
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
            .vulkan = Vulkan.init(data.gpa, data.asset_server, data.fonts, data.models, data.texture_slots, data.window) catch |err| {
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
    // ponytail: asset loaders are NOT re-registered here, so after a swap they keep
    // running the previous image's code (harmless — it is never unloaded). They are
    // setup-path, not hot-path; re-registering would mean tearing down and rematching
    // live GPU resources. Symptom if it ever bites: an edit to *Loader.zig appears to
    // do nothing. Fix is a restart.
    pub export fn renderReload(handle: *anyopaque, pre_reload: bool) void {
        if (pre_reload) return;
        const context: *Context = @ptrCast(@alignCast(handle));
        shared.log_io = context.io;
        context.vulkan.rebindProcs();
    }

    pub export fn renderUpdate(handle: *anyopaque, packet: *DrawList) void {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.update(packet) catch |err| {
            std.log.err("render update: {s}", .{@errorName(err)});
        };
    }
};
