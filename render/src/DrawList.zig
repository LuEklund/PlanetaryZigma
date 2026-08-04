const DrawList = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("Renderer/Vulkan/Shader.zig");
const Emitter = @import("Emitter.zig");
const Ui = @import("Ui.zig");

pub const max_debug_vertices: u32 = 65536;
pub const max_joint_matrices: u32 = 16384;
pub const max_lines: u32 = max_debug_vertices / 2;
pub const max_draw_models: u32 = shared.max_entities * 8;

camera: Camera,
time: f32,
light_color: [4]f32,
draw_sky: bool,
draw_models: std.ArrayList(DrawModel),
joint_matrices: std.ArrayList(nz.Mat4x4(f32)),
draw_lines: std.ArrayList(Line),
emitters: std.ArrayList(PacketEmitter),
ui: UiLayer,
planet: PlanetState,
surface_width: u32,
surface_height: u32,

pub const Camera = struct {
    position: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    fov_rad: f32,
};

pub const DrawModel = struct {
    kind: shared.entity.Kind,
    model_matrix: nz.Mat4x4(f32),
    position: nz.Vec3(f32),
    mesh_id: ?u32,
    palette_offset: ?u32,
};

pub const Line = struct {
    a: nz.Vec3(f32),
    b: nz.Vec3(f32),
    color: [4]f32,
};

pub const PacketEmitter = struct {
    effect: Shader.Kind,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
    spawn_time: f32,
};

pub const UiLayer = struct {
    quads: std.ArrayList(Ui.Quad),
    screen_width: f32,
    screen_height: f32,
};

pub const PlanetState = struct {
    id: shared.entity.Id,
    transform: nz.Mat4x4(f32),
    radius: u32,
    anchor_position: nz.Vec3(f32),
    view_distance: i32,
};

pub fn init(gpa: std.mem.Allocator) !DrawList {
    return .{
        .camera = .{ .position = @splat(0), .rotation = .identity, .fov_rad = 0 },
        .time = 0,
        .light_color = .{ 1, 1, 1, 1 },
        .draw_sky = false,
        .draw_models = try .initCapacity(gpa, max_draw_models),
        .joint_matrices = try .initCapacity(gpa, max_joint_matrices),
        .draw_lines = try .initCapacity(gpa, max_lines),
        .emitters = try .initCapacity(gpa, Emitter.max_emitters),
        .surface_width = 0,
        .surface_height = 0,
        .ui = .{ .quads = try .initCapacity(gpa, Ui.max_ui_quads), .screen_width = 0, .screen_height = 0 },
        .planet = .{ .id = .none, .transform = .identity, .radius = 0, .anchor_position = @splat(0), .view_distance = 1 },
    };
}

pub fn deinit(self: *DrawList, gpa: std.mem.Allocator) void {
    self.draw_models.deinit(gpa);
    self.joint_matrices.deinit(gpa);
    self.draw_lines.deinit(gpa);
    self.emitters.deinit(gpa);
    self.ui.quads.deinit(gpa);
}

pub fn clear(self: *DrawList) void {
    self.draw_models.clearRetainingCapacity();
    self.joint_matrices.clearRetainingCapacity();
    self.draw_lines.clearRetainingCapacity();
    self.emitters.clearRetainingCapacity();
    self.ui.quads.clearRetainingCapacity();
}
