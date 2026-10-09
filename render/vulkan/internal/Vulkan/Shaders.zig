const Shaders = @This();

const std = @import("std");
const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const Shader = @import("renderer_contract").Shader;
const PipelineLayout = @import("PipelineLayout.zig");
const Swapchain = @import("Swapchain.zig");
const check = @import("utils.zig").check;

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
    ui,
};

const Blend = enum { none, alpha, additive };
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
    .ui = .{ .vert = .ui, .frag = .ui, .layout = .ui, .target = .main, .blend = .alpha, .lines = false },
});

const dynamic_states = [_]c.VkDynamicState{
    c.VK_DYNAMIC_STATE_VIEWPORT_WITH_COUNT,
    c.VK_DYNAMIC_STATE_SCISSOR_WITH_COUNT,
    c.VK_DYNAMIC_STATE_CULL_MODE,
    c.VK_DYNAMIC_STATE_FRONT_FACE,
    c.VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY,
    c.VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE,
    c.VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE,
    c.VK_DYNAMIC_STATE_DEPTH_COMPARE_OP,
    c.VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE,
    c.VK_DYNAMIC_STATE_DEPTH_BIAS,
    c.VK_DYNAMIC_STATE_LINE_WIDTH,
};

device: Device,
pipeline_layouts: std.EnumArray(PipelineLayout.Kind, c.VkPipelineLayout),
modules: std.EnumArray(Shader.Kind, c.VkShaderModule),
pipelines: std.EnumArray(Pipeline, c.VkPipeline),

pub fn init(device: Device, pipeline_layouts: std.EnumArray(PipelineLayout.Kind, c.VkPipelineLayout)) Shaders {
    return .{
        .device = device,
        .pipeline_layouts = pipeline_layouts,
        .modules = .initFill(null),
        .pipelines = .initFill(null),
    };
}

pub fn deinit(self: *Shaders) void {
    for (self.pipelines.values) |pipeline| if (pipeline != null) c.vkDestroyPipeline(self.device.handle, pipeline, null);
    for (self.modules.values) |module| if (module != null) c.vkDestroyShaderModule(self.device.handle, module, null);
}

pub fn get(self: *const Shaders, pipeline: Pipeline) c.VkPipeline {
    return self.pipelines.get(pipeline);
}

pub fn apply(self: *Shaders, kind: Shader.Kind, spirv: []align(4) const u8) !void {
    const module_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len,
        .pCode = @ptrCast(spirv.ptr),
    };
    var module: c.VkShaderModule = null;
    try check(c.vkCreateShaderModule(self.device.handle, &module_info, null, &module));

    const old_module = self.modules.get(kind);
    if (old_module != null) {
        try check(c.vkDeviceWaitIdle(self.device.handle));
        c.vkDestroyShaderModule(self.device.handle, old_module, null);
    }
    self.modules.set(kind, module);

    for (std.enums.values(Pipeline)) |pipeline| {
        const row = rows.get(pipeline);
        if (row.vert != kind and row.frag != kind) continue;
        if (self.modules.get(row.vert) == null) continue;
        if (row.frag) |frag| if (self.modules.get(frag) == null) continue;

        const built = try self.build(row);
        const old_pipeline = self.pipelines.get(pipeline);
        if (old_pipeline != null) {
            try check(c.vkDeviceWaitIdle(self.device.handle));
            c.vkDestroyPipeline(self.device.handle, old_pipeline, null);
        }
        self.pipelines.set(pipeline, built);
    }
}

fn build(self: *Shaders, row: Row) !c.VkPipeline {
    var stages: [2]c.VkPipelineShaderStageCreateInfo = undefined;
    stages[0] = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = self.modules.get(row.vert),
        .pName = Shader.get(row.vert).vert.?.ptr,
    };
    var stage_count: u32 = 1;
    if (row.frag) |frag| {
        stages[1] = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = self.modules.get(frag),
            .pName = Shader.get(frag).frag.?.ptr,
        };
        stage_count = 2;
    }

    const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    };
    const input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = if (row.lines) c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST else c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    const viewport: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    };
    const rasterization: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_BACK_BIT,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1,
    };
    const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
    };
    const depth_stencil: c.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.VK_TRUE,
        .depthWriteEnable = c.VK_TRUE,
        .depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
    };
    const color_attachment: c.VkPipelineColorBlendAttachmentState = switch (row.blend) {
        .none => .{
            .blendEnable = c.VK_FALSE,
            .colorWriteMask = all_components,
        },
        .alpha => .{
            .blendEnable = c.VK_TRUE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = all_components,
        },
        .additive => .{
            .blendEnable = c.VK_TRUE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = all_components,
        },
    };
    const color_format: c.VkFormat = switch (row.target) {
        .main => Swapchain.draw_format,
        .mask => Swapchain.mask_format,
        .shadow => c.VK_FORMAT_UNDEFINED,
    };
    const color_count: u32 = if (row.target == .shadow) 0 else 1;
    const color_blend: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = color_count,
        .pAttachments = &color_attachment,
    };
    const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    const rendering: c.VkPipelineRenderingCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = color_count,
        .pColorAttachmentFormats = &color_format,
        .depthAttachmentFormat = if (row.target == .mask) c.VK_FORMAT_UNDEFINED else Swapchain.depth_format,
    };
    const pipeline_info: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering,
        .stageCount = stage_count,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = self.pipeline_layouts.get(row.layout),
    };
    var pipeline: c.VkPipeline = null;
    try check(c.vkCreateGraphicsPipelines(self.device.handle, null, 1, &pipeline_info, null, &pipeline));
    return pipeline;
}

const all_components: c.VkColorComponentFlags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
