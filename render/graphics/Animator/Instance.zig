const Instance = @This();

const std = @import("std");
const shared = @import("shared");
const nz = @import("numz");
const Model = @import("../assets/root.zig").Model;
const Node = @import("../assets/root.zig").Node;

model: u32,
offset: nz.Transform3D(f32),
highlight: bool,
spin_speed: f32,
shrink_on_death: bool,
transform: nz.Transform3D(f32),
is_dying: bool,
is_local: bool,
state: shared.entity.State,
spawn_time: f32,
death_time: f32,
spin_time: f32,
skeleton: ?Skeleton,

pub const fade_duration: f32 = 0.15;

const block_align: u29 = @max(
    @alignOf(nz.Mat4x4(f32)),
    @alignOf(Node),
    @alignOf(JointTransform),
    @alignOf(u32),
);

pub const Player = struct {
    current_time: f32 = 0,
    active: usize = 0,
};

pub const JointTransform = struct {
    translation: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    scale: nz.Vec3(f32),
};

pub const Skeleton = struct {
    /// The single allocation the slices below point into. Freed as one.
    block: []align(block_align) u8,
    nodes: []Node,
    fade_joints: []JointTransform,
    fade_time: f32,
    /// One block for every skin's palette, contiguous so the draw walk is a single memcpy.
    /// `skin_starts[i]` is where skin i begins; `skin_starts[skins.len]` is the total.
    joints: []nz.Mat4x4(f32),
    skin_starts: []u32,
    player: Player,
    overlay: ?Player,

    pub fn init(gpa: std.mem.Allocator, model: *const Model) !Skeleton {
        const node_count = model.nodes.items.len;
        var joint_count: u32 = 0;
        for (model.skins) |skin| joint_count += @intCast(skin.inverse_bind_matrices.?.len);

        // ONE allocation for the whole pose: an instance is 1 alloc / 1 free, so entities
        // spawning and dying cannot fragment the heap with four differently-sized blocks.
        // Regions are ordered by descending alignment and carved by offset.
        const joints_bytes = @sizeOf(nz.Mat4x4(f32)) * joint_count;
        const nodes_at = std.mem.alignForward(usize, joints_bytes, @alignOf(Node));
        const fade_at = std.mem.alignForward(usize, nodes_at + @sizeOf(Node) * node_count, @alignOf(JointTransform));
        const starts_at = std.mem.alignForward(usize, fade_at + @sizeOf(JointTransform) * node_count, @alignOf(u32));
        const total_bytes = starts_at + @sizeOf(u32) * (model.skins.len + 1);

        const block = try gpa.alignedAlloc(u8, .fromByteUnits(block_align), total_bytes);
        errdefer gpa.free(block);

        const joints: []nz.Mat4x4(f32) = @alignCast(std.mem.bytesAsSlice(nz.Mat4x4(f32), block[0..joints_bytes]));
        const nodes: []Node = @alignCast(std.mem.bytesAsSlice(Node, block[nodes_at..][0 .. @sizeOf(Node) * node_count]));
        const fade_joints: []JointTransform = @alignCast(std.mem.bytesAsSlice(JointTransform, block[fade_at..][0 .. @sizeOf(JointTransform) * node_count]));
        const skin_starts: []u32 = @alignCast(std.mem.bytesAsSlice(u32, block[starts_at..][0 .. @sizeOf(u32) * (model.skins.len + 1)]));

        @memcpy(nodes, model.nodes.items);
        @memset(joints, .identity);
        var running: u32 = 0;
        for (model.skins, 0..) |skin, skin_index| {
            skin_starts[skin_index] = running;
            running += @intCast(skin.inverse_bind_matrices.?.len);
        }
        skin_starts[model.skins.len] = running;

        return .{
            .block = block,
            .nodes = nodes,
            .fade_joints = fade_joints,
            .fade_time = 0,
            .joints = joints,
            .skin_starts = skin_starts,
            .player = .{},
            .overlay = null,
        };
    }

    pub fn deinit(self: *Skeleton, gpa: std.mem.Allocator) void {
        gpa.free(self.block);
    }

    pub fn startFade(self: *Skeleton) void {
        for (self.nodes, self.fade_joints) |node, *pose| {
            pose.* = .{ .translation = node.translation, .rotation = node.rotation, .scale = node.scale };
        }
        self.fade_time = fade_duration;
    }

    pub fn playClip(self: *Skeleton, model: *const Model, clip_index: usize) void {
        self.startFade();
        self.player = .{
            .current_time = model.clips[clip_index].start,
            .active = clip_index,
        };
    }

    pub fn playOverlay(self: *Skeleton, model: *const Model, clip_index: usize) void {
        self.startFade();
        self.overlay = .{
            .current_time = model.clips[clip_index].start,
            .active = clip_index,
        };
    }
};

pub fn init(gpa: std.mem.Allocator, model_handle: u32, model: *const Model) !Instance {
    return .{
        .model = model_handle,
        .offset = .{ .position = @splat(0), .rotation = .identity, .scale = @splat(1) },
        .highlight = false,
        .spin_speed = 0,
        .shrink_on_death = false,
        .transform = .{},
        .is_dying = false,
        .is_local = false,
        .state = .idle,
        .spawn_time = 0,
        .death_time = 0,
        .spin_time = 0,
        .skeleton = if (model.isSkinned()) try Skeleton.init(gpa, model) else null,
    };
}

pub fn deinit(self: *Instance, gpa: std.mem.Allocator) void {
    if (self.skeleton) |*skeleton| skeleton.deinit(gpa);
}
