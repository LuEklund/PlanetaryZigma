const std = @import("std");
const Window = @import("Window");
const Vulkan = @import("Renderer/Vulkan.zig");
const Resources = @import("Renderer/Vulkan/Resources.zig");
const FramePacket = @import("Renderer/FramePacket.zig");
const AssetServer = @import("AssetServer.zig");
const shared = @import("shared");
const DynLib = shared.DynLib;

// Each .so carries its own copy of shared's globals, so this one needs its own log
// wiring exactly like System.init does — otherwise the first log here reads a null io.
pub const std_options: std.Options = .{ .logFn = shared.logFn };

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    asset_server: *AssetServer,
    window: *Window,
};

const Context = struct {
    gpa: std.mem.Allocator,
    vulkan: *Vulkan,
};

pub const Table = struct {
    renderInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    renderDeinit: *const fn (*anyopaque) callconv(.c) void,
    renderResources: *const fn (*anyopaque) callconv(.c) *Resources,
    renderResize: *const fn (*anyopaque, width: u32, height: u32) callconv(.c) bool,
    renderDrain: *const fn (*anyopaque, commands: [*]const FramePacket.RenderCommand, count: usize) callconv(.c) bool,
    renderUpdate: *const fn (*anyopaque, packet: *FramePacket) callconv(.c) bool,
    renderReload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,

    pub fn load(dynlib: *DynLib) !Table {
        var self: Table = undefined;
        inline for (std.meta.fields(Table)) |field| {
            const ptr = dynlib.lookup(field.type, field.name) orelse {
                std.log.err("render: failed to lookup symbol {s}", .{field.name});
                return error.DynlibLookup;
            };
            @field(self, field.name) = ptr;
        }
        return self;
    }
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
            .vulkan = Vulkan.init(data.gpa, data.asset_server, data.window) catch |err| {
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

    pub export fn renderResources(handle: *anyopaque) *Resources {
        const context: *Context = @ptrCast(@alignCast(handle));
        return context.vulkan.resources;
    }

    pub export fn renderResize(handle: *anyopaque, width: u32, height: u32) bool {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.resize(context.gpa, width, height) catch |err| {
            std.log.err("render resize: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub export fn renderDrain(handle: *anyopaque, commands: [*]const FramePacket.RenderCommand, count: usize) bool {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.drainRenderCommands(context.gpa, commands[0..count]) catch |err| {
            std.log.err("render drain: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub export fn renderUpdate(handle: *anyopaque, packet: *FramePacket) bool {
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.update(packet) catch |err| {
            std.log.err("render update: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub export fn renderReload(handle: *anyopaque, pre_reload: bool) void {
        if (pre_reload) return;
        const context: *Context = @ptrCast(@alignCast(handle));
        context.vulkan.rebindProcs();
    }
};
