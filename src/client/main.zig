const std = @import("std");

const glfw = @import("glfw");
const shared = @import("shared");

const Renderer = @import("Renderer.zig");

pub fn main(init: std.process.Init) !void {
    _ = glfw.glfwInit();
    defer glfw.glfwTerminate();

    var renderer: Renderer = try .init(init.gpa);
    defer renderer.deinit();

    glfw.glfwWindowHint(glfw.GLFW_NO_API, glfw.GLFW_TRUE);

    const window: *glfw.GLFWwindow = glfw.glfwCreateWindow(900, 800, "PlanetaryZigma", null, null) orelse return error.CreateWindow;
    defer glfw.glfwDestroyWindow(window);

    while (glfw.glfwWindowShouldClose(window) != glfw.GLFW_TRUE) {}

    // std.debug.print("client\n", .{});
    // const io = init.io;
    // _ = try io.sleep(.fromSeconds(1), .real);
    // const stream = try shared.net.address.connect(io, .{ .mode = .stream });
    // defer stream.close(io);

    // var stream_reader_buffer: [128]u8 = undefined;
    // var stream_reader = stream.reader(io, &stream_reader_buffer);
    // const reader = &stream_reader.interface;

    // while (true) {
    //     reader.fillMore() catch |err| switch (err) {
    //         error.EndOfStream => break,
    //         else => return err,
    //     };

    //     const read = reader.buffered();

    //     std.debug.print("from server: {s}\n", .{read});

    //     reader.tossBuffered();
    // }
}
