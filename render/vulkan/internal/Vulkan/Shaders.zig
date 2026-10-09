const Shaders = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("device.zig").Logical;
const Shader = @import("renderer_contract").Shader;
const PipelineLayout = @import("PipelineLayout.zig");
const Swapchain = @import("Swapchain.zig");

pub const Pipeline = enum {
    shadow_static,
    shadow_skinned,
    highlight_static,
    highlight_skinned,
    opaque_static,
    opaque_skinned,
    transparent_static,
    transparent_skinned,
    sky,
    particles_alpha,
    particles_additive,
    outline,
    debug,
    dvui,
};

const Blend = enum { none, alpha, additive, premultiplied };
const Target = enum { main, shadow, mask };

const Row = struct {
    vert: Shader.Kind,
    frag: ?Shader.Kind,
    layout: PipelineLayout.Kind,
    target: Target,
    blend: Blend,
    lines: bool,
};

const rows: std.EnumArray(Pipeline, Row) = .init(.{
    .shadow_static = .{ .vert = .shadow_static, .frag = null, .layout = .world, .target = .shadow, .blend = .none, .lines = false },
    .shadow_skinned = .{ .vert = .shadow_skinned, .frag = null, .layout = .world, .target = .shadow, .blend = .none, .lines = false },
    .highlight_static = .{ .vert = .highlight_static, .frag = .highlight_static, .layout = .world, .target = .mask, .blend = .none, .lines = false },
    .highlight_skinned = .{ .vert = .highlight_skinned, .frag = .highlight_static, .layout = .world, .target = .mask, .blend = .none, .lines = false },
    .opaque_static = .{ .vert = .static, .frag = .mesh, .layout = .world, .target = .main, .blend = .none, .lines = false },
    .opaque_skinned = .{ .vert = .skinned, .frag = .mesh, .layout = .world, .target = .main, .blend = .none, .lines = false },
    .transparent_static = .{ .vert = .static, .frag = .mesh, .layout = .world, .target = .main, .blend = .alpha, .lines = false },
    .transparent_skinned = .{ .vert = .skinned, .frag = .mesh, .layout = .world, .target = .main, .blend = .alpha, .lines = false },
    .sky = .{ .vert = .sky, .frag = .sky, .layout = .sky, .target = .main, .blend = .none, .lines = false },
    .particles_alpha = .{ .vert = .particles, .frag = .particles, .layout = .particle, .target = .main, .blend = .alpha, .lines = false },
    .particles_additive = .{ .vert = .particles, .frag = .particles, .layout = .particle, .target = .main, .blend = .additive, .lines = false },
    .outline = .{ .vert = .highlight_outline, .frag = .highlight_outline, .layout = .world, .target = .main, .blend = .none, .lines = false },
    .debug = .{ .vert = .debug, .frag = .debug, .layout = .world, .target = .main, .blend = .none, .lines = true },
    .dvui = .{ .vert = .dvui, .frag = .dvui, .layout = .dvui, .target = .main, .blend = .premultiplied, .lines = false },
});

const dynamic_states = [_]vk.DynamicState{
    .viewport_with_count,
    .scissor_with_count,
    .cull_mode,
    .front_face,
    .primitive_topology,
    .depth_test_enable,
    .depth_write_enable,
    .depth_compare_op,
    .depth_bias_enable,
    .depth_bias,
    .line_width,
};

const all_components: vk.ColorComponentFlags = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true };

device: Device,
pipeline_layouts: std.EnumArray(PipelineLayout.Kind, vk.PipelineLayout),
modules: std.EnumArray(Shader.Kind, vk.ShaderModule),
pipelines: std.EnumArray(Pipeline, vk.Pipeline),

pub fn init(device: Device, pipeline_layouts: std.EnumArray(PipelineLayout.Kind, vk.PipelineLayout)) Shaders {
    return .{
        .device = device,
        .pipeline_layouts = pipeline_layouts,
        .modules = .initFill(.null_handle),
        .pipelines = .initFill(.null_handle),
    };
}

pub fn deinit(self: *Shaders) void {
    for (self.pipelines.values) |pipeline| if (pipeline != .null_handle) self.device.proxy.destroyPipeline(pipeline, null);
    for (self.modules.values) |module| if (module != .null_handle) self.device.proxy.destroyShaderModule(module, null);
}

pub fn get(self: *const Shaders, pipeline: Pipeline) vk.Pipeline {
    return self.pipelines.get(pipeline);
}

pub fn apply(self: *Shaders, kind: Shader.Kind, spirv: []align(4) const u8) !void {
    const module = try self.device.proxy.createShaderModule(&.{
        .code_size = spirv.len,
        .p_code = @ptrCast(spirv.ptr),
    }, null);

    const old_module = self.modules.get(kind);
    if (old_module != .null_handle) {
        try self.device.proxy.deviceWaitIdle();
        self.device.proxy.destroyShaderModule(old_module, null);
    }
    self.modules.set(kind, module);

    for (std.enums.values(Pipeline)) |pipeline| {
        const row = rows.get(pipeline);
        if (row.vert != kind and row.frag != kind) continue;
        if (self.modules.get(row.vert) == .null_handle) continue;
        if (row.frag) |frag| if (self.modules.get(frag) == .null_handle) continue;

        const built = try self.build(row);
        const old_pipeline = self.pipelines.get(pipeline);
        if (old_pipeline != .null_handle) {
            try self.device.proxy.deviceWaitIdle();
            self.device.proxy.destroyPipeline(old_pipeline, null);
        }
        self.pipelines.set(pipeline, built);
    }
}

fn build(self: *Shaders, row: Row) !vk.Pipeline {
    var stages: [2]vk.PipelineShaderStageCreateInfo = undefined;
    stages[0] = .{ .stage = .{ .vertex_bit = true }, .module = self.modules.get(row.vert), .p_name = Shader.get(row.vert).vert.?.ptr };
    var stage_count: u32 = 1;
    if (row.frag) |frag| {
        stages[1] = .{ .stage = .{ .fragment_bit = true }, .module = self.modules.get(frag), .p_name = Shader.get(frag).frag.?.ptr };
        stage_count = 2;
    }

    const color_attachment = [_]vk.PipelineColorBlendAttachmentState{switch (row.blend) {
        .none => .{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = all_components,
        },
        .alpha => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = all_components,
        },
        .premultiplied => .{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = all_components,
        },
        .additive => .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .zero,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = all_components,
        },
    }};
    const color_format = [_]vk.Format{switch (row.target) {
        .main => Swapchain.draw_format,
        .mask => Swapchain.mask_format,
        .shadow => .undefined,
    }};
    const color_count: u32 = if (row.target == .shadow) 0 else 1;

    const rendering: vk.PipelineRenderingCreateInfo = .{
        .view_mask = 0,
        .color_attachment_count = color_count,
        .p_color_attachment_formats = &color_format,
        .depth_attachment_format = if (row.target == .mask) .undefined else Swapchain.depth_format,
        .stencil_attachment_format = .undefined,
    };
    const create_info = [_]vk.GraphicsPipelineCreateInfo{.{
        .p_next = &rendering,
        .stage_count = stage_count,
        .p_stages = &stages,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{
            .topology = if (row.lines) .line_list else .triangle_list,
            .primitive_restart_enable = .false,
        },
        .p_viewport_state = &.{},
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            .depth_compare_op = .less_or_equal,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = color_count,
            .p_attachments = &color_attachment,
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states },
        .layout = self.pipeline_layouts.get(row.layout),
        .subpass = 0,
        .base_pipeline_index = -1,
    }};
    var pipeline: [1]vk.Pipeline = undefined;
    _ = try self.device.proxy.createGraphicsPipelines(.null_handle, &create_info, null, &pipeline);
    return pipeline[0];
}
