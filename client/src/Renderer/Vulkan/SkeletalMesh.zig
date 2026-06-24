const std = @import("std");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Node = @import("Node.zig");
const Skin = @import("Skin.zig");
const Animation = @import("Animation.zig");
const RenderResources = @import("RenderResources.zig");

device: Device,
vma: Vma,
model_name: []const u8,
render_resources: *RenderResources,
nodes: std.ArrayList(Node) = .empty,
top_nodes: std.ArrayList(usize) = .empty,
clips: std.ArrayList(Animation) = .empty,
skins: std.ArrayList(Skin) = .empty,
offset: nz.Transform3D(f32) = .{},
READY_RELOAD_DELETE_THIS: bool = false,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    model_name: []const u8,
    render_resources: *RenderResources,
    offset: nz.Transform3D(f32),
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .model_name = try gpa.dupe(u8, model_name),
        .render_resources = render_resources,
        .nodes = .empty,
        .top_nodes = .empty,
        .clips = .empty,
        .skins = .empty,
        .offset = offset,
    };
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    for (self.nodes.items) |*node| node.deinit(gpa);
    self.nodes.deinit(gpa);
    for (self.clips.items) |*animation| animation.deinit(gpa);
    self.clips.deinit(gpa);
    for (self.skins.items) |*skin| skin.deinit(gpa, self.vma);
    self.skins.deinit(gpa);
    self.top_nodes.deinit(gpa);
    gpa.free(self.model_name);
    self.* = undefined;
    gpa.destroy(self);
}
