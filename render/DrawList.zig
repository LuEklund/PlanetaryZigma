const DrawList = @This();

const std = @import("std");
const nz = @import("numz");
const contract = @import("renderer_contract.zig");

pub const max_joint_matrices: u32 = 16384;
pub const max_lines: u32 = 262144;
pub const max_emitters: u32 = 1024;
pub const max_draw_meshes: u32 = 1024 * 32;

camera: Camera,
time: f32,
light_color: [4]f32,
sun_direction: nz.Vec3(f32),
sky_zenith: [4]f32,
sky_horizon: [4]f32,
draw_sky: bool,
draw_meshes: std.ArrayList(DrawMesh),
joint_matrices: std.ArrayList(nz.Mat4x4(f32)),
draw_lines: std.ArrayList(Line),
emitters: std.ArrayList(DrawEmitter),
dvui: DvuiLayer,
planet_radius: f32,
post: Post,
surface_width: u32,
surface_height: u32,

pub const Post = struct {
    bloom_strength: f32 = 0.5,
    bloom_threshold: f32 = 1.1,
    exposure: f32 = 1,
    saturation: f32 = 1.08,
    vignette: f32 = 0.25,
    fxaa: bool = true,
};

pub const Camera = struct {
    position: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    fov_rad: f32,
};

pub const DrawMesh = struct {
    mesh: contract.MeshHandle,
    model_matrix: nz.Mat4x4(f32),
    position: nz.Vec3(f32),
    palette_offset: ?u32,
    skinned: bool,
    highlight: bool,
    tint: [4]f32 = .{ 1, 1, 1, 0 },
};

pub const Line = struct {
    a: nz.Vec3(f32),
    b: nz.Vec3(f32),
    color: [4]f32,
};

pub const DrawEmitter = struct {
    effect: contract.ParticleEffect,
    origin: nz.Vec3(f32),
    target: nz.Vec3(f32),
    spawn_time: f32,
};

pub const max_dvui_vertices: u32 = 1 << 17;
pub const max_dvui_indices: u32 = 3 << 17;
pub const max_dvui_commands: u32 = 8192;

pub const DvuiVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: u32,
};

pub const DvuiClip = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const DvuiCommand = struct {
    texture: contract.TextureHandle,
    clip: ?DvuiClip,
    index_start: u32,
    index_count: u32,
};

pub const DvuiLayer = struct {
    vertices: std.ArrayList(DvuiVertex),
    indices: std.ArrayList(u32),
    commands: std.ArrayList(DvuiCommand),
};


pub fn init(gpa: std.mem.Allocator) !DrawList {
    return .{
        .camera = .{ .position = @splat(0), .rotation = .identity, .fov_rad = 0 },
        .time = 0,
        .light_color = .{ 1, 1, 1, 1 },
        .sun_direction = .{ 0, 1, 0 },
        .sky_zenith = .{ 0.3, 0.5, 0.85, 1 },
        .sky_horizon = .{ 0.8, 0.85, 0.9, 1 },
        .draw_sky = false,
        .draw_meshes = try .initCapacity(gpa, max_draw_meshes),
        .joint_matrices = try .initCapacity(gpa, max_joint_matrices),
        .draw_lines = try .initCapacity(gpa, max_lines),
        .emitters = try .initCapacity(gpa, max_emitters),
        .post = .{},
        .surface_width = 0,
        .surface_height = 0,
        .dvui = .{
            .vertices = try .initCapacity(gpa, max_dvui_vertices),
            .indices = try .initCapacity(gpa, max_dvui_indices),
            .commands = try .initCapacity(gpa, max_dvui_commands),
        },
        .planet_radius = 1,
    };
}

pub fn deinit(self: *DrawList, gpa: std.mem.Allocator) void {
    self.draw_meshes.deinit(gpa);
    self.joint_matrices.deinit(gpa);
    self.draw_lines.deinit(gpa);
    self.emitters.deinit(gpa);
    self.dvui.vertices.deinit(gpa);
    self.dvui.indices.deinit(gpa);
    self.dvui.commands.deinit(gpa);
}

pub fn clear(self: *DrawList) void {
    self.draw_meshes.clearRetainingCapacity();
    self.joint_matrices.clearRetainingCapacity();
    self.draw_lines.clearRetainingCapacity();
    self.emitters.clearRetainingCapacity();
}
