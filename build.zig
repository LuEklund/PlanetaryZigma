const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.addModule("shared", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // const client_step = b.step("client", "Client step");
    const client_exe = client(b, target, optimize, shared);

    // const server_step = b.step("server", "Client step");
    const server_exe = server(b, target, optimize, shared);

    const run_step = b.step("run", "Run the app");
    const client_run_cmd = b.addRunArtifact(client_exe);
    const server_run_cmd = b.addRunArtifact(server_exe);
    run_step.dependOn(&client_run_cmd.step);
    run_step.dependOn(&server_run_cmd.step);
    client_run_cmd.step.dependOn(b.getInstallStep());
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        client_run_cmd.addArgs(args);
        server_run_cmd.addArgs(args);
    }
}

// TODO(ernesto): HOT RELOADING
pub fn client(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, shared: *std.Build.Module) *std.Build.Step.Compile {
    // TODO(etakarinaee): use harald lib
    const glfw_headers = b.dependency("glfw_headers", .{});
    const glfw_translate_c = b.addTranslateC(.{
        .root_source_file = glfw_headers.path("include/GLFW/glfw3.h"),
        // b.addWriteFiles().add("c.h",
        // \\#define GLFW_INCLUDE_NONE
        // \\#include <GLFW/glfw3.h>
        // ),
        .target = target,
        .optimize = optimize,
    });

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("vulkan.c",
            \\#include <stdint.h>
            \\typedef struct {} Display;
            \\typedef unsigned int Window;
            \\typedef unsigned int VisualID;
            \\typedef uint32_t DWORD;
            \\typedef void* HANDLE;
            \\typedef const uint16_t* LPCWSTR;
            \\typedef HANDLE HMONITOR;
            \\typedef HANDLE HINSTANCE;
            \\typedef HANDLE HWND; 
            \\
            \\typedef struct _SECURITY_ATTRIBUTES {
            \\    DWORD  nLength;
            \\    void* lpSecurityDescriptor;
            \\    int    bInheritHandle; 
            \\} SECURITY_ATTRIBUTES;
            \\
            \\#include <vulkan/vulkan.h>
            \\#include <vulkan/vulkan_win32.h>
            \\#include <vulkan/vulkan_wayland.h>
            \\#include <vulkan/vulkan_xlib.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    vulkan.addIncludePath(vulkan_headers.path("include"));

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },

                .{ .name = "glfw", .module = glfw_translate_c.createModule() },
                .{ .name = "vulkan", .module = vulkan.createModule() },
            },
        }),
    });

    exe.root_module.linkLibrary(b.dependency("glfw", .{ .target = target, .optimize = optimize }).artifact("glfw3"));

    switch (target.result.os.tag) {
        .windows, .wasi => exe.root_module.linkSystemLibrary("vulkan-1", .{}),
        else => exe.root_module.linkSystemLibrary("vulkan", .{}),
    }

    b.installArtifact(exe);

    return exe;
}

pub fn server(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, shared: *std.Build.Module) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
            },
        }),
    });
    b.installArtifact(exe);

    return exe;
}
