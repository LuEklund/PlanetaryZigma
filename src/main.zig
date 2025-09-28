const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const stb = @import("stb");

var vertices = [_]f32{
    -0.5, -0.5, 0.0, 0.0, 0.0,
    -0.5, 0.5,  0.0, 0.0, 1.0,
    0.5,  0.5,  0.0, 1.0, 1.0,
    0.5,  -0.5, 0.0, 1.0, 0.0,
};

var indices = [_]u32{
    0, 2, 1,
    0, 3, 2,
};

pub const vertex: [*:0]const u8 =
    \\#version 460 core
    \\layout (location = 0) in vec3 pos;
    \\layout (location = 1) in vec2 uvs;
    \\
    \\out vec2 UVs;
    \\
    \\uniform mat4 u_projection;
    \\uniform mat4 u_model;
    \\
    \\void main() {
    \\    gl_Position = u_projection * u_model * vec4(pos, 1.0);
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

    glfw.opengl.makeContextCurrent(window);
    defer glfw.opengl.makeContextCurrent(null);

    try gl.init(glfw.opengl.getProcAddress);
    gl.debug.set(null);

    const vertex_shader: gl.Shader = .init(.vertex);
    defer vertex_shader.deinit();
    vertex_shader.source(vertex);
    try vertex_shader.compile();

    const fragment_shader: gl.Shader = .init(.fragment);
    defer fragment_shader.deinit();
    fragment_shader.source(fragment);
    try fragment_shader.compile();

    const program: gl.Program = try .init();
    defer program.deinit();
    program.attach(vertex_shader);
    program.attach(fragment_shader);
    try program.link();

    const vao: gl.Vao = try .init();
    const vbo: gl.Buffer = try .init();
    const ebo: gl.Buffer = try .init();
    defer vao.deinit();
    defer vbo.deinit();
    defer ebo.deinit();

    vbo.bufferData(.static_draw, &vertices);
    ebo.bufferData(.static_draw, &indices);

    vao.vertexAttribute(0, 0, 3, f32, false, 0);
    vao.vertexAttribute(1, 0, 2, f32, false, 3 * @sizeOf(f32));

    vao.vertexBuffer(vbo, 0, 0, 5 * @sizeOf(f32));
    vao.elementBuffer(ebo);

    vao.bind();

    gl.State.enable(.blend, null);
    gl.c.glBlendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA); // TODO: use wrapped implementation (doesn't exist yet)

    const player_image: Image = try .init("assets/textures/zigger.png");
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

        gl.clear.color(0.1, 0.5, 0.3, 1.0);
        gl.clear.buffer(.{ .color = true, .depth = true });
        gl.draw.viewport(0, 0, width, height);

        const yaw = player.transform.rotation[1]; // yaw (around Y axis)
        const pitch = player.transform.rotation[0]; // pitch (around X axis)

        const view: nz.Mat4x4(f32) = .lookAt(
            player.transform.position,
            player.transform.position + nz.Vec3(f32){
                @cos(yaw) * @cos(pitch),
                @sin(pitch),
                @sin(yaw) * @cos(pitch),
            },
            nz.Vec3(f32){ 0, 1, 0 },
        );

        const perspective: nz.Mat4x4(f32) = .perspective(
            std.math.degreesToRadians(45),
            @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
            1,
            300,
        );

        const projection: nz.Mat4x4(f32) = .mul(perspective, view);

        program.use();
        try program.setUniform("u_projection", .{ .f32x4x4 = projection.d });
        try program.setUniform("u_model", .{
            .f32x4x4 = (nz.Transform3D(f32){
                .position = .{ 0, 0, -10 },
                .rotation = .{ 0, @mod(time * 100, 360), 0 },
            }).toMat4x4().d,
        });
        player_texture.bind(0);

        gl.draw.elements(.triangles, indices.len, u32, null);

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

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: [*]u8,

    pub fn init(file_path: [*:0]const u8) !@This() {
        var width: c_int = undefined;
        var height: c_int = undefined;
        var channels: c_int = undefined;
        // 4 = RGBA
        stb.stbi_set_flip_vertically_on_load(@intFromBool(true));
        const pixels = stb.stbi_load(file_path, &width, &height, &channels, 4) orelse {
            std.log.err("Failed to load image: {s}", .{stb.stbi_failure_reason()});
            return error.LoadImage;
        };
        return .{ .width = @intCast(width), .height = @intCast(height), .pixels = @ptrCast(pixels) };
    }

    pub fn deinit(self: @This()) void {
        stb.stbi_image_free(@ptrCast(self.pixels));
    }

    pub fn toTexture(self: @This()) !gl.Texture {
        const texture: gl.Texture = try .init(.@"2d");

        texture.setParamater(.{ .min_filter = .linear });
        texture.setParamater(.{ .mag_filter = .linear });
        texture.setParamater(.{ .wrap = .{ .s = .repeat, .t = .repeat } });

        texture.store(.{ .@"2d" = .{ .levels = 1, .format = .rgba8, .width = self.width, .height = self.height } });
        texture.setSubImage(.{ .@"2d" = .{ .width = self.width, .height = self.height } }, 0, .rgba8, self.pixels);

        return texture;
    }
};

pub const Player = struct {
    transform: nz.Transform3D(f32) = .{},

    pub fn update(self: *@This(), window: *glfw.Window, delta_time: f32) void {
        const speed: f32 = if (glfw.io.Key.left_shift.get(window)) 13 else 3;
        if (glfw.io.Key.a.get(window)) self.transform.position[0] -= speed * delta_time;
        if (glfw.io.Key.d.get(window)) self.transform.position[0] += speed * delta_time;
        if (glfw.io.Key.w.get(window)) self.transform.position[2] += speed * delta_time;
        if (glfw.io.Key.s.get(window)) self.transform.position[2] -= speed * delta_time;
        if (glfw.io.Key.space.get(window)) self.transform.position[1] += speed * delta_time;
        if (glfw.io.Key.left_shift.get(window)) self.transform.position[1] -= speed * delta_time;

        if (glfw.io.Key.left.get(window)) self.transform.rotation[1] -= speed * delta_time;
        if (glfw.io.Key.right.get(window)) self.transform.rotation[1] += speed * delta_time;
    }
};
