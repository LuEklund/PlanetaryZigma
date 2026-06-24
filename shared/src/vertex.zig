pub const StaticVertex = extern struct {
    position: [3]f32 = @splat(0),
    uv_x: f32 = 0,
    normal: [3]f32 = @splat(0),
    uv_y: f32 = 0,
    color: [4]f32 = @splat(0),
};

pub const SkinnedVertex = extern struct {
    position: [3]f32 = @splat(0),
    uv_x: f32 = 0,
    normal: [3]f32 = @splat(0),
    uv_y: f32 = 0,
    color: [4]f32 = @splat(0),
    joint_indices: [4]i32 = @splat(-1),
    joint_weights: [4]f32 = @splat(-1),
};
