const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const Render = @import("Render.zig");

var vertices = [_]f32{
    1, 1, 1, 1.0, 0.0,
    1, 1, 0, 0.0, 0.0,
    1, 0, 1, 1.0, 1.0,
    1, 0, 0, 0.0, 1.0,
    0, 1, 1, 0.0, 0.0,
    0, 1, 0, 1.0, 0.0,
    0, 0, 1, 0.0, 1.0,
    0, 0, 0, 1.0, 1.0,
};

var indices = [_]u32{
    // Front face
    4, 6, 0,
    0, 6, 2,
    // Back face
    1, 3, 5,
    5, 3, 7,
    // Right face
    0, 2, 1,
    1, 2, 3,
    // Left face
    5, 7, 4,
    4, 7, 6,
    // Top face
    4, 0, 5,
    5, 0, 1,
    // Bottom face
    6, 7, 2,
    2, 7, 3,
};

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
    try glfw.init();
    defer glfw.deinit();

    glfw.Window.Hint.set(.{ .context_version_major = 4 });
    glfw.Window.Hint.set(.{ .context_version_minor = 6 });
    glfw.Window.Hint.set(.{ .opengl_profile = .core });

    const window: *glfw.Window = try .init(.{
        .title = "Hello, world!",
        .size = .{ .width = 900, .height = 800 },
    });
    defer window.deinit();

    Render.init();
    defer Render.deinit();

    const pipeline = try Render.pipeline.init(vertex, fragment);
    defer pipeline.deinit();

    const model: Render.Model = try .init(&vertices, &indices);
    defer model.deinit();

    const player_image: Render.Image = try .init("assets/textures/tile.png");
    defer player_image.deinit();
    const player_texture = try player_image.toTexture();
    defer player_texture.deinit();

    var player: Player = .{};

    var time: f32 = 0;
    while (!window.shouldClose()) {
        const delta_time = try getDeltaTime();
        time += delta_time;
        glfw.io.events.poll();
        const width: usize, const height: usize = window.getSize().toArray();

        player.update(window, delta_time);

        gl.State.enable(.blend, null);
        gl.c.glBlendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA); // TODO: use wrapped implementation (doesn't exist yet)

        if (glfw.io.Key.p.get(window)) {
            gl.State.enable(.depth_test, null);
            gl.c.glDepthFunc(gl.c.GL_LESS);
        } else {
            gl.State.disable(.depth_test, null);
        }

        gl.clear.buffer(.{ .color = true, .depth = true });
        gl.clear.color(0.1, 0.5, 0.3, 1.0);
        gl.clear.depth(1000);

        gl.draw.viewport(0, 0, width, height);

        const camera_mat: nz.Mat4x4(f32) = camera.toMat4x4(player.transform, @floatFromInt(width), @floatFromInt(height), 1.0, 10_000.0);

        pipeline.use();
        try pipeline.setUniform("u_camera", .{ .f32x4x4 = camera_mat.d });

        player_texture.bind(0);

        model.draw(.{
            .position = .{ @cos(time / 10) * 30, @cos(time / 10) * 1, @sin(time / 10) * 30 },
            .rotation = .{ 0, @mod(time * 100, 360), 0 },
        });

        try glfw.opengl.swapBuffers(window);
        try window.setTitle(@ptrCast(try std.fmt.allocPrint(std.heap.page_allocator, "{d:2.2} fps", .{1 / delta_time})));
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

pub const Player = struct {
    transform: nz.Transform3D(f32) = .{},
    speed: f32 = 10,
    sensitivity: f64 = 1,

    pub fn update(self: *@This(), window: *glfw.Window, delta_time: f32) void {
        if (glfw.io.Key.p.get(window)) std.debug.print("{any}\n", .{self.transform});
        const pitch = &self.transform.rotation[0];
        const yaw = &self.transform.rotation[1];

        pitch.* = std.math.clamp(pitch.*, std.math.degreesToRadians(-89.9), std.math.degreesToRadians(89.9));

        const forward = nz.vec.forward(self.transform.position, self.transform.position + nz.Vec3(f32){ @cos(yaw.*) * @cos(pitch.*), @sin(pitch.*), @sin(yaw.*) * @cos(pitch.*) });
        const right: nz.Vec3(f32) = nz.vec.normalize(nz.vec.cross(forward, .{ 0, 1, 0 }));
        const up = nz.vec.normalize(nz.vec.cross(right, forward));

        var move: nz.Vec3(f32) = .{ 0, 0, 0 };
        const velocity = self.speed * delta_time;

        if (glfw.io.Key.w.get(window)) move -= nz.vec.scale(forward, velocity);
        if (glfw.io.Key.s.get(window)) move += nz.vec.scale(forward, velocity);
        if (glfw.io.Key.a.get(window)) move += nz.vec.scale(right, velocity);
        if (glfw.io.Key.d.get(window)) move -= nz.vec.scale(right, velocity);
        if (glfw.io.Key.space.get(window)) move += nz.vec.scale(up, velocity);
        // if (app.isKeyDown(.rctrl)) move -= nz.vec.scale(up, velocity);

        const speed_multiplier: f32 = if (glfw.io.Key.left_shift.get(window)) 3.25 else if (glfw.io.Key.left_control.get(window)) 0.1 else 2;

        self.transform.position += nz.vec.scale(move, speed_multiplier);

        if (glfw.io.Key.r.get(window)) {
            yaw.* = 0;
            pitch.* = 0;
            self.transform.position = .{ 0, 0, 0 };
        }

        if (glfw.io.Key.left.get(window)) self.transform.rotation[1] -= self.speed * delta_time;
        if (glfw.io.Key.right.get(window)) self.transform.rotation[1] += self.speed * delta_time;
    }
};

pub const camera = struct {
    /// Builds a projection * view matrix for the given transform.
    /// near = 1.0, far = 10000.0 by default.
    pub fn toMat4x4(
        transform: nz.Transform3D(f32),
        width: f32,
        height: f32,
        near: f32,
        far: f32,
    ) nz.Mat4x4(f32) {
        // assuming transform.rotation = { pitch, yaw, roll } in radians
        const pitch = transform.rotation[0];
        const yaw = transform.rotation[1];
        // roll is ignored for a basic FPS-style camera

        // Forward vector from yaw/pitch
        const forward: nz.Vec3(f32) = nz.vec.normalize(nz.Vec3(f32){
            @cos(yaw) * @cos(pitch),
            @sin(pitch),
            @sin(yaw) * @cos(pitch),
        });

        const up: nz.Vec3(f32) = .{ 0.0, 1.0, 0.0 };

        const view: nz.Mat4x4(f32) = .lookAt(
            transform.position,
            transform.position + forward,
            up,
        );

        const proj: nz.Mat4x4(f32) = .perspective(
            std.math.degreesToRadians(45.0),
            width / height,
            near,
            far,
        );

        return .mul(proj, view); // Projection * View
    }
};
