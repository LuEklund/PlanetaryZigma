const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const Render = @import("render.zig");

pub const vertex: [*:0]const u8 =
    \\#version 460 core
    \\layout (location = 0) in vec3 pos;
    \\layout (location = 1) in vec2 uvs;
    \\
    \\out vec2 UVs;
    \\
    \\uniform mat4 u_camera;
    \\uniform mat4 u_model;
    \\
    \\void main() {
    \\    gl_Position = u_camera * u_model * vec4(pos, 1.0);
    \\    UVs = uvs;
    \\}
;

pub const fragment: [*:0]const u8 =
    \\#version 460 core
    \\in vec2 UVs;
    \\out vec4 FragColor;
    \\
    \\uniform sampler2D tex;
    \\
    \\void main() {
    \\    FragColor = texture(tex, UVs);
    \\}
;

pub fn main() !void {
    const window = Render.init();
    defer Render.deinit(window);

    const pipeline = Render.initPipeline(vertex, fragment);
    defer Render.deinitPipeline(pipeline);

    var time: f32 = 0;
    while (!window.shouldClose()) {
        const delta_time = try getDeltaTime();
        time += delta_time;
        Render.draw(pipeline, window);
    }
}

pub fn getDeltaTime() !f32 {
    const Static = struct {
        var previous: ?std.time.Instant = null;
    };

    const now = try std.time.Instant.now();
    const prev = Static.previous orelse {
        Static.previous = now;
        return 0.0;
    };

    const dt_ns = now.since(prev);
    Static.previous = now;

    return @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
}
