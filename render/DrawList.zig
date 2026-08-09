const DrawList = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Shader = @import("shared").Shader;
const Emitter = @import("shared").Emitter;
const Ui = @import("shared").Ui;

pub const max_joint_matrices: u32 = 16384;
pub const max_lines: u32 = 262144;
pub const max_draw_meshes: u32 = shared.max_entities * 32;

camera: Camera,
time: f32,
light_color: [4]f32,
draw_sky: bool,
draw_meshes: std.ArrayList(DrawMesh),
joint_matrices: std.ArrayList(nz.Mat4x4(f32)),
draw_lines: std.ArrayList(Line),
emitters: std.ArrayList(DrawEmitter),
ui: UiLayer,
planet: PlanetState,
/// Asset bytes read above the boundary; the backend creates GPU objects from them and
/// keeps nothing. Owned by the producer, valid only for this frame's renderUpdate.
asset_uploads: []const AssetUpload,
surface_width: u32,
surface_height: u32,

pub const Camera = struct {
    position: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    fov_rad: f32,
};

/// How many built-in primitive meshes the backend keeps. The producer maps its own names
/// onto these indices; render never learns what they mean.
pub const max_generated: u32 = 4;

/// Which GPU mesh to draw. The producer resolved this; the backend does no lookup.
pub const MeshRef = union(enum) {
    generated: u32,
    file: struct { model: u32, mesh: u32 },
};

/// One row is one draw unit, which is what makes depth sorting possible above the boundary.
pub const DrawMesh = struct {
    mesh: MeshRef,
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

pub const UiLayer = struct {
    quads: std.ArrayList(Ui.Quad),
    screen_width: f32,
    screen_height: f32,
};

/// One queue, in arrival order. The backend drains it with one switch, so adding an asset
/// kind is one variant here and one arm there.
pub const AssetUpload = union(enum) {
    shader: ShaderUpload,
    texture: TextureUpload,
    font: FontUpload,
    model: ModelUpload,
};

pub const ShaderUpload = struct {
    kind: Shader.Kind,
    spirv: []align(4) const u8,
};

pub const TextureUpload = struct {
    slot: u32,
    width: u32,
    height: u32,
    /// One entry is a 2D texture; six is a cubemap, in Vulkan face order.
    faces: []const []const u8,
};

pub const FontUpload = struct {
    index: u32,
    /// R8 coverage for the whole atlas; glyph metrics were already written producer-side.
    coverage: []const u8,
};

/// A model upload is a plain command: geometry and pixels, no parser types. Whoever
/// produced it (glTF today, anything tomorrow) fills these in; the backend only makes
/// GPU objects out of them.
pub const ModelUpload = struct {
    index: u32,
    meshes: []const MeshUpload,
    images: []const ImageUpload,
    samplers: []const SamplerUpload,
};

pub const MeshUpload = struct {
    name: []const u8,
    /// Raw vertex bytes; `skinned` picks the layout to reinterpret them as.
    vertices: []const u8,
    skinned: bool,
    indices: []const u32,
    surfaces: []const SurfaceUpload,
};

pub const SurfaceUpload = struct {
    index_start: u32,
    index_count: u32,
    image_index: ?u32,
    material_missing: bool,
};

pub const ImageUpload = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
    sampler_index: ?u32,
};

pub const SamplerUpload = struct {
    mag_linear: bool,
    min_linear: bool,
};

pub const PlanetState = struct {
    radius: f32,
    uploads: []const shared.Planet.Upload,
    removes: []const shared.Planet.Chunk.Coord,
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
        .emitters = try .initCapacity(gpa, Emitter.max_emitters),
        .surface_width = 0,
        .surface_height = 0,
        .ui = .{ .quads = try .initCapacity(gpa, Ui.max_ui_quads), .screen_width = 0, .screen_height = 0 },
        .planet = .{ .radius = 1, .uploads = &.{}, .removes = &.{} },
        .asset_uploads = &.{},
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
