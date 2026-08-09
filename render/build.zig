const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // No preferred_optimize_mode here: that swaps -Doptimize for -Drelease, and the
    // consuming package passes .optimize down explicitly. The ReleaseSafe default
    // stays where the executables are built.
    const optimize = b.standardOptimizeOption(.{});

    const tracy_enable = b.option(bool, "tracy", "Enable Tracy profiling") orelse false;
    const ztracy = b.dependency("ztracy", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("ztracy");
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize, .tracy = tracy_enable }).module("shared");

    const win32 = b.dependency("win32", .{}).module("win32");

    const window = b.addModule("Window", .{
        .root_source_file = b.path("src/Window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "win32", .module = win32 },
        },
        .link_libc = true,
    });
    switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd => {
            const scanner = @import("wayland").Scanner.create(b, .{});
            const wayland_protocols = b.dependency("wayland_protocols", .{});

            const wayland = b.createModule(.{
                .root_source_file = scanner.result,
                .target = target,
                .optimize = optimize,
            });

            scanner.addCustomProtocol(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
            scanner.addCustomProtocol(wayland_protocols.path("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"));
            scanner.addCustomProtocol(wayland_protocols.path("staging/cursor-shape/cursor-shape-v1.xml"));
            scanner.addCustomProtocol(wayland_protocols.path("unstable/tablet/tablet-unstable-v2.xml"));
            scanner.addCustomProtocol(wayland_protocols.path("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"));
            scanner.addCustomProtocol(wayland_protocols.path("unstable/relative-pointer/relative-pointer-unstable-v1.xml"));

            scanner.generate("wl_compositor", 1);
            scanner.generate("wl_output", 4);
            scanner.generate("wl_shm", 1);
            scanner.generate("wl_seat", 4);
            scanner.generate("wl_data_device_manager", 3);
            scanner.generate("xdg_wm_base", 3);
            scanner.generate("wp_cursor_shape_manager_v1", 2);
            scanner.generate("zxdg_decoration_manager_v1", 1);
            scanner.generate("zwp_tablet_manager_v2", 1);
            scanner.generate("zwp_pointer_constraints_v1", 1);
            scanner.generate("zwp_relative_pointer_manager_v1", 1);

            const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");

            const libxkbcommon = b.dependency("libxkbcommon", .{
                .target = target,
                .optimize = optimize,
                .@"xkb-config-root" = "/usr/share/X11/xkb",
                .@"x-locale-root" = "/usr/share/X11/locale",
            }).artifact("xkbcommon");

            xkbcommon.linkLibrary(libxkbcommon);

            window.addImport("wayland", wayland);
            window.addImport("xkbcommon", xkbcommon);
        },
        else => {},
    }

    const zgltf = b.dependency("zgltf", .{ .target = target, .optimize = optimize }).module("zgltf");

    const stb_dep = b.dependency("stb", .{});
    const stb_image = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_image.addIncludePath(stb_dep.path("."));

    const stb_truetype = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_truetype.addIncludePath(stb_dep.path("."));

    const vulkandeps = b.dependency("vulkan_headers", .{});
    const vmadep = b.dependency("vma", .{});

    const vulkan_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("vma_vulkan.h",
            \\#include <vulkan/vulkan.h>
            \\#include <vk_mem_alloc.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    vulkan_c.addIncludePath(vulkandeps.path("include/"));
    vulkan_c.addIncludePath(vmadep.path("include/"));

    const vulkan = vulkan_c.createModule();
    vulkan.link_libcpp = true;
    for (vulkan_c.include_dirs.items) |include_dir| vulkan.addIncludePath(include_dir.path);

    vulkan.addCSourceFile(.{
        .file = b.addWriteFiles().add("vma_impl.cpp",
            \\#define VMA_STATIC_VULKAN_FUNCTIONS 1
            \\#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
            \\#define VMA_IMPLEMENTATION
            \\#include <vk_mem_alloc.h>
        ),
        // Hidden like stb: with default visibility VMA's symbols are GC roots, so they
        // survive at full size in libsystem_client.so — which never calls one — and drag
        // libvulkan in with them. Both .so files also exported them, so which copy won
        // depended on dlopen order.
        .flags = &.{ "-std=c++17", "-fvisibility=hidden" },
    });

    const stbi_impl = b.addWriteFiles().add("stbi_impl.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#include "stb_image.h"
        \\#define STB_TRUETYPE_IMPLEMENTATION
        \\#include "stb_truetype.h"
    );

    // The contract module. src/root.zig no longer names a single backend file, so a
    // consumer's compilation cannot reach Vulkan.zig at all — an edit there rebuilds
    // render.so and leaves system_client.so byte-identical. Verified by the probe in
    // src/root.zig's header comment; re-run it if you add an import there.
    const render = b.addModule("render", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared", .module = shared },
            .{ .name = "Window", .module = window },
            .{ .name = "zgltf", .module = zgltf },
            .{ .name = "stb_image", .module = stb_image.createModule() },
            .{ .name = "stb_truetype", .module = stb_truetype.createModule() },
            .{ .name = "ztracy", .module = ztracy },
        },
        .link_libc = true,
    });
    // Hidden, not exported: both .so roots compile this source, so without this 102 stb
    // symbols are global in both and ELF interposition picks by dlopen order.
    render.addCSourceFile(.{ .file = stbi_impl, .flags = &.{"-fvisibility=hidden"} });
    render.addIncludePath(stb_dep.path("."));

    // The same sources plus `vulkan`, compiled as its own .so so a renderer edit does
    // not rebuild the game systems.
    const backend = b.addLibrary(.{
        .name = "render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vulkan/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "Window", .module = window },
                .{ .name = "zgltf", .module = zgltf },
                .{ .name = "stb_image", .module = stb_image.createModule() },
                .{ .name = "stb_truetype", .module = stb_truetype.createModule() },
                .{ .name = "ztracy", .module = ztracy },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "render", .module = render },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
        .linkage = .dynamic,
    });
    // No stbi_impl here: the backend imports the `render` module, which already carries
    // that C source, so adding it again is a duplicate-symbol link error.
    linkVulkan(b, backend, target);
    b.installArtifact(backend);
}

// The release-only trap: --as-needed drops libvulkan when nothing references it at
// link time, and the dlopen inside Vulkan then fails. Travels with the package so any
// binary touching Vulkan gets the same treatment.
pub fn linkVulkan(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
            compile.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "Lib" }) });
        } else {
            std.log.warn("VULKAN_SDK not set; vulkan-1 may not be found at link time", .{});
        }
        compile.root_module.linkSystemLibrary("vulkan-1", .{});
    } else {
        compile.root_module.linkSystemLibrary("vulkan", .{});
        if (compile.isDynamicLibrary()) compile.link_z_defs = true;
    }
}
