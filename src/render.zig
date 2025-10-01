const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const stb = @import("stb");

const Player = struct {};

pub export fn init(window: *glfw.Window) void {
    glfw.opengl.makeContextCurrent(window);

    gl.init(glfw.opengl.getProcAddress) catch |err| @panic(@errorName(err));
    gl.debug.set(null);
}

pub export fn deinit() void {
    glfw.opengl.makeContextCurrent(null);
}

pub const pipeline = struct {
    pub fn init(vertex: [*:0]const u8, fragment: [*:0]const u8) !gl.Program {
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

pub const Model = extern struct {
    vao: gl.Vao,
    vbo: gl.Buffer,
    ebo: gl.Buffer,
    index_count: usize,

    pub fn init(vertices: anytype, indices: anytype) !@This() {
        const vao: gl.Vao = try .init();
        const vbo: gl.Buffer = try .init();
        const ebo: gl.Buffer = try .init();

        vbo.bufferData(.static_draw, vertices);
        ebo.bufferData(.static_draw, indices);

        vao.vertexAttribute(0, 0, 3, f32, false, 0);
        vao.vertexAttribute(1, 0, 2, f32, false, 3 * @sizeOf(f32));

        vao.vertexBuffer(vbo, 0, 0, 5 * @sizeOf(f32));
        vao.elementBuffer(ebo);

        return .{
            .vao = vao,
            .vbo = vbo,
            .ebo = ebo,
            .index_count = indices.len,
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
        transform: nz.Transform3D(f32),
    ) !void {
        self.vao.bind();
        try program.setUniform("u_model", .{ .f32x4x4 = transform.toMat4x4().d });

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
