const std = @import("std");

const gl = @import("gl");
const glfw = @import("glfw");
const nz = @import("numz");
const stb = @import("stb");

pub var players: [32]Player = undefined;
pub var player_count: usize = 0;
pub var model: Model = undefined;
pub var player_image: Image = undefined;
pub var player_texture: gl.Texture = undefined;

//TODO: Do this fr xd
// const GameState = struct {
//     players: std.ArrayList(Player) = undefined,
// };

pub const DbVector3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

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

pub export fn init() *glfw.Window {
    const window = initWindow() catch |err| @panic(@errorName(err));

    glfw.opengl.makeContextCurrent(window);

    gl.init(glfw.opengl.getProcAddress) catch |err| @panic(@errorName(err));
    gl.debug.set(null);
    return window;
}

pub fn initWindow() !*glfw.Window {
    try glfw.init();

    glfw.Window.Hint.set(.{ .context_version_major = 4 });
    glfw.Window.Hint.set(.{ .context_version_minor = 6 });
    glfw.Window.Hint.set(.{ .opengl_profile = .core });

    const window: *glfw.Window = try .init(.{
        .title = "Hello, world!",
        .size = .{ .width = 900, .height = 800 },
    });
    return window;
}

pub export fn deinit(window: *glfw.Window) void {
    glfw.opengl.makeContextCurrent(null);
    window.deinit();
    glfw.deinit();
}

pub export fn initPipeline() gl.Program {
    std.log.debug("Model\n", .{});
    model = Model.init() catch return @enumFromInt(0);
    std.log.debug("Image\n", .{});
    player_image = Image.init("assets/textures/tile.png") catch return @enumFromInt(0);
    std.log.debug("Textire\n", .{});
    player_texture = player_image.toTexture() catch return @enumFromInt(0);
    std.log.debug("Pipeline\n", .{});
    return pipeline.init() catch @enumFromInt(0);
}

pub export fn deinitPipeline(program: gl.Program) void {
    model.deinit();
    player_texture.deinit();
    player_image.deinit();
    program.deinit();
}
pub export fn update(
    window: *glfw.Window,
    delta_time: f32,
) void {
    glfw.io.events.poll();
    players[0].update(window, delta_time);
}

pub export fn draw(
    program: gl.Program,
    window: *glfw.Window,
) void {
    const width: usize, const height: usize = window.getSize().toArray();

    gl.State.enable(.blend, null);
    gl.c.glBlendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA); // TODO: use wrapped implementation (doesn't exist yet)

    gl.clear.buffer(.{ .color = true, .depth = true });
    gl.clear.color(0.1, 0.5, 0.3, 1.0);
    gl.clear.depth(1000);
    gl.draw.viewport(0, 0, width, height);

    const camera_mat: nz.Mat4x4(f32) = camera.toMat4x4(players[0].transform, @floatFromInt(width), @floatFromInt(height), 1.0, 10_000.0);
    program.use();

    program.setUniform("u_camera", .{ .f32x4x4 = camera_mat.d }) catch {
        std.log.debug("ERR", .{});
        return;
    };

    player_texture.bind(0);

    for (0..player_count) |i| {
        const og_pos = model.transform.position[0];
        model.transform.position[0] = @floatFromInt(i);
        model.transform.position[0] = -model.transform.position[0];
        model.draw(program) catch {
            std.log.debug("ERR-1", .{});
            continue;
        };
        model.transform.position[0] = og_pos;
    }

    glfw.opengl.swapBuffers(window) catch {
        std.log.debug("ERR2", .{});
        return;
    };
    const tmp = std.fmt.allocPrint(std.heap.page_allocator, "{d:2.2} fps", .{1 / 16}) catch {
        std.log.debug("ERR2", .{});
        return;
    };
    window.setTitle(@ptrCast(tmp)) catch {
        std.log.debug("ERR2", .{});
        return;
    };
}

pub export fn player_connect(id: u32) void {
    std.log.debug("Player COnnected {d}", .{player_count});
    players[player_count] = .{ .id = id };
    player_count += 1;
}

pub export fn update_player_pos(id: u32, new_pos: DbVector3) void {
    for (0..@min(player_count, 32)) |i| {
        if (players[i].id == id) {
            std.log.debug(" FOUND PLAYER {d}", .{id});
            players[i].transform.position = .{ new_pos.x, new_pos.y, new_pos.z };
            return;
        }
    }
}

pub export fn player_disconnect() void {
    player_count -= 1;
}

pub export fn is_key_down(
    key: c_int,
    window: *glfw.Window,
) bool {
    const glfw_key: glfw.io.Key =
        switch (key) {
            0 => .w,
            1 => .s,
            2 => .a,
            3 => .d,
            else => unreachable,
        };
    return glfw_key.get(window);
}

pub const pipeline = struct {
    pub fn init() !gl.Program {
        const vertex_shader: gl.Shader = .init(.vertex);
        defer vertex_shader.deinit();
        vertex_shader.source(vertex);
        try vertex_shader.compile();

        const fragment_shader: gl.Shader = .init(.fragment);
        defer fragment_shader.deinit();
        fragment_shader.source(fragment);
        try fragment_shader.compile();

        const program: gl.Program = try .init();
        program.attach(vertex_shader);
        program.attach(fragment_shader);
        try program.link();

        return program;
    }
};

pub const Model = struct {
    vao: gl.Vao,
    vbo: gl.Buffer,
    ebo: gl.Buffer,
    index_count: usize,
    transform: nz.Transform3D(f32),

    pub fn init() !@This() {
        const vao: gl.Vao = try .init();
        const vbo: gl.Buffer = try .init();
        const ebo: gl.Buffer = try .init();

        vbo.bufferData(.static_draw, &vertices);
        ebo.bufferData(.static_draw, &indices);

        vao.vertexAttribute(0, 0, 3, f32, false, 0);
        vao.vertexAttribute(1, 0, 2, f32, false, 3 * @sizeOf(f32));

        vao.vertexBuffer(vbo, 0, 0, 5 * @sizeOf(f32));
        vao.elementBuffer(ebo);

        return .{
            .vao = vao,
            .vbo = vbo,
            .ebo = ebo,
            .index_count = indices.len,
            .transform = .{},
        };
    }

    pub fn deinit(self: @This()) void {
        self.ebo.deinit();
        self.vbo.deinit();
        self.vao.deinit();
    }

    pub fn draw(
        self: @This(),
        program: gl.Program,
    ) !void {
        self.vao.bind();
        try program.setUniform("u_model", .{ .f32x4x4 = self.transform.toMat4x4().d });
        gl.draw.elements(.triangles, self.index_count, u32, null);
    }
};

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
    speed: f32 = 10,
    sensitivity: f64 = 1,
    id: u32 = 0,

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
