const Backend = @This();

const std = @import("std");
const dvui = @import("dvui");
const contract = @import("renderer_contract");
const DrawList = contract.DrawList;

const GenericError = dvui.Backend.GenericError;
const TextureError = dvui.Backend.TextureError;

pub const kind: dvui.enums.RenderBackend = .default;

pub const Frame = struct {
    draw_list: *DrawList,
    render_api: *const contract.Api,
    render_handle: *anyopaque,
};

io: std.Io,
size: dvui.Size.Physical,
scale: f32,
text_input_wanted: bool,
frame: ?Frame,

pub fn backend(self: *Backend) dvui.Backend {
    return .init(self);
}

pub fn nanoTime(self: *Backend) i128 {
    return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
}

pub fn sleep(self: *Backend, ns: u64) void {
    std.Io.sleep(self.io, .fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn deinit(_: *Backend) void {}

pub fn begin(self: *Backend, _: std.mem.Allocator) GenericError!void {
    const layer = &self.frame.?.draw_list.dvui;
    layer.vertices.clearRetainingCapacity();
    layer.indices.clearRetainingCapacity();
    layer.commands.clearRetainingCapacity();
}

pub fn end(_: *Backend) GenericError!void {}

pub fn pixelSize(self: *Backend) dvui.Size.Physical {
    return self.size;
}

pub fn windowSize(self: *Backend) dvui.Size.Natural {
    return .{ .w = self.size.w / self.scale, .h = self.size.h / self.scale };
}

pub fn contentScale(self: *Backend) f32 {
    return self.scale;
}

pub fn drawClippedTriangles(
    self: *Backend,
    texture: ?dvui.Texture,
    vtx: []const dvui.Vertex,
    idx: []const dvui.Vertex.Index,
    clipr: ?dvui.Rect.Physical,
) GenericError!void {
    const layer = &self.frame.?.draw_list.dvui;
    if (layer.vertices.items.len + vtx.len > layer.vertices.capacity or
        layer.indices.items.len + idx.len > layer.indices.capacity or
        layer.commands.items.len == layer.commands.capacity)
    {
        std.log.debug("dvui: draw list full, dropping {d} triangles", .{idx.len / 3});
        return;
    }
    layer.commands.appendAssumeCapacity(.{
        .texture = if (texture) |t| handleOf(t.ptr) else .blank,
        .clip = if (clipr) |r| .{
            .x = @intFromFloat(@floor(r.x)),
            .y = @intFromFloat(@floor(r.y)),
            .width = @intFromFloat(@ceil(@max(0, r.w))),
            .height = @intFromFloat(@ceil(@max(0, r.h))),
        } else null,
        .index_start = @intCast(layer.indices.items.len),
        .index_count = @intCast(idx.len),
    });
    const base: u32 = @intCast(layer.vertices.items.len);
    for (vtx) |vertex| layer.vertices.appendAssumeCapacity(.{
        .position = .{ vertex.pos.x, vertex.pos.y },
        .uv = vertex.uv,
        .color = @bitCast(vertex.col),
    });
    for (idx) |index| layer.indices.appendAssumeCapacity(base + index);
}

pub fn textureCreate(
    self: *Backend,
    pixels: [*]const u8,
    options: dvui.Texture.CreateOptions,
) TextureError!dvui.Texture {
    const frame = self.frame orelse return error.TextureCreate;
    const linear = options.interpolation == .linear;
    const handle = frame.render_api.uploadImage(frame.render_handle, &.{
        .width = options.width,
        .height = options.height,
        .pixels = pixels[0 .. options.width * options.height * 4],
        .r8 = false,
        .mips = false,
        .mag_linear = linear,
        .min_linear = linear,
    });
    if (handle == .missing) return error.TextureCreate;
    return .{
        .ptr = @ptrFromInt(@as(usize, @intFromEnum(handle)) + 1),
        .width = options.width,
        .height = options.height,
        .format = options.format,
        .interpolation = options.interpolation,
        .wrap_u = options.wrap_u,
        .wrap_v = options.wrap_v,
    };
}

pub fn textureDestroy(self: *Backend, texture: dvui.Texture) void {
    const frame = self.frame orelse return;
    frame.render_api.freeImage(frame.render_handle, handleOf(texture.ptr));
}

pub fn textureFor(handle: contract.TextureHandle, width: u32, height: u32) dvui.Texture {
    return .{
        .ptr = @ptrFromInt(@as(usize, @intFromEnum(handle)) + 1),
        .width = width,
        .height = height,
        .format = .rgba_32,
        .interpolation = .linear,
        .wrap_u = .clamp,
        .wrap_v = .clamp,
    };
}

fn handleOf(ptr: *anyopaque) contract.TextureHandle {
    return @enumFromInt(@intFromPtr(ptr) - 1);
}

pub fn textureCreateTarget(
    _: *Backend,
    _: dvui.Texture.CreateOptions,
) TextureError!dvui.TextureTarget {
    return error.NotImplemented;
}

pub fn textureReadTarget(_: *Backend, _: dvui.TextureTarget, _: [*]u8) TextureError!void {
    return error.NotImplemented;
}

pub fn textureClearTarget(_: *Backend, _: dvui.TextureTarget) void {}

pub fn textureDestroyTarget(_: *Backend, _: dvui.TextureTarget) void {}

pub fn textureFromTarget(_: *Backend, _: dvui.TextureTarget) TextureError!dvui.Texture {
    return error.NotImplemented;
}

pub fn renderTarget(_: *Backend, _: ?dvui.TextureTarget) GenericError!void {}

pub fn setCursor(_: *Backend, _: dvui.enums.Cursor) void {}

pub fn textInputRect(self: *Backend, rect: ?dvui.Rect.Natural) void {
    self.text_input_wanted = rect != null;
}

pub fn renderPresent(_: *Backend) void {}

pub fn clipboardText(_: *Backend) GenericError![]const u8 {
    return &.{};
}

pub fn clipboardTextSet(_: *Backend, _: []const u8) GenericError!void {}

pub fn openURL(_: *Backend, _: []const u8, _: bool) GenericError!void {}

pub fn preferredColorScheme(_: *Backend) ?dvui.enums.ColorScheme {
    return .dark;
}

pub fn prefersReducedMotion(_: *Backend) bool {
    return false;
}

pub fn refresh(_: *Backend) void {}
