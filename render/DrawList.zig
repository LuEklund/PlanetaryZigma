const DrawList = @This();

const std = @import("std");
const nz = @import("numz");
const Shader = @import("Shader.zig");
const contract = @import("root.zig");

pub const max_joint_matrices: u32 = 16384;
pub const max_lines: u32 = 262144;
pub const max_emitters: u32 = 1024;
/// The packet's own ceiling, not the sim's: 1024 things on screen, up to 32 meshes each.
pub const max_draw_meshes: u32 = 1024 * 32;

camera: Camera,
time: f32,
light_color: [4]f32,
draw_sky: bool,
draw_meshes: std.ArrayList(DrawMesh),
joint_matrices: std.ArrayList(nz.Mat4x4(f32)),
draw_lines: std.ArrayList(Line),
emitters: std.ArrayList(DrawEmitter),
ui: UiLayer,
planet_radius: f32,
surface_width: u32,
surface_height: u32,

pub const Camera = struct {
    position: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    fov_rad: f32,
};

/// One row is one draw unit, which is what makes depth sorting possible above the boundary.
pub const DrawMesh = struct {
    mesh: contract.MeshHandle,
    model_matrix: nz.Mat4x4(f32),
    position: nz.Vec3(f32),
    palette_offset: ?u32,
    skinned: bool,
    highlight: bool,
};

pub const Line = struct {
    a: nz.Vec3(f32),
    b: nz.Vec3(f32),
    color: [4]f32,
};

pub const DrawEmitter = struct {
    effect: Shader.Kind,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
    spawn_time: f32,
};

pub const max_ui_quads: usize = 2048;

/// The UI vertex layout. It is a GPU format, so it belongs with the renderer; the widget
/// system that produces it is a separate module entirely.
pub const UiVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    texture_index: u32 = 0,
    is_sdf: u32 = 0,
    _: [2]u32 = .{ 0, 0 },
};

pub const UiQuad = struct {
    vertices: [4]UiVertex,
};

pub const UiLayer = struct {
    quads: std.ArrayList(UiQuad),
    screen_width: f32,
    screen_height: f32,
};

pub const TextureUpload = struct {
    slot: u32,
    width: u32,
    height: u32,
    /// One entry is a 2D texture; six is a cubemap, in Vulkan face order.
    faces: []const []const u8,
};

pub fn init(gpa: std.mem.Allocator) !DrawList {
    return .{
        .camera = .{ .position = @splat(0), .rotation = .identity, .fov_rad = 0 },
        .time = 0,
        .light_color = .{ 1, 1, 1, 1 },
        .draw_sky = false,
        .draw_meshes = try .initCapacity(gpa, max_draw_meshes),
        .joint_matrices = try .initCapacity(gpa, max_joint_matrices),
        .draw_lines = try .initCapacity(gpa, max_lines),
        .emitters = try .initCapacity(gpa, max_emitters),
        .surface_width = 0,
        .surface_height = 0,
        .ui = .{ .quads = try .initCapacity(gpa, max_ui_quads), .screen_width = 0, .screen_height = 0 },
        .planet_radius = 1,
    };
}

pub fn deinit(self: *DrawList, gpa: std.mem.Allocator) void {
    self.draw_meshes.deinit(gpa);
    self.joint_matrices.deinit(gpa);
    self.draw_lines.deinit(gpa);
    self.emitters.deinit(gpa);
    self.ui.quads.deinit(gpa);
}

pub fn clear(self: *DrawList) void {
    self.draw_meshes.clearRetainingCapacity();
    self.joint_matrices.clearRetainingCapacity();
    self.draw_lines.clearRetainingCapacity();
    self.emitters.clearRetainingCapacity();
    self.ui.quads.clearRetainingCapacity();
}
