# 0010 — Vulkan 1.3 core only: pipelines + descriptor sets

## What
- `VK_EXT_shader_object` and `VK_EXT_descriptor_buffer` removed, plus the
  `VK_LAYER_KHRONOS_shader_object` emulation layer. The only device extension
  left is `VK_KHR_swapchain`.
- `Shaders.zig` keeps one `VkShaderModule` per `Shader.Kind` and a comptime
  `Pipeline` table (vert kind, frag kind, pipeline layout, target, blend,
  lines). Uploading a shader rebuilds every pipeline row that uses that kind, so
  shader hot reload still works.
- Blend is baked into the pipeline (opaque / alpha / additive rows). Everything
  else the old code set per pass is core 1.3 dynamic state: viewport/scissor
  with count, cull mode, front face, topology, depth test/write/compare, depth
  bias enable + values, line width.
- Descriptor sets from one pool: per-frame scene set (uniform buffer), per-frame
  shadow set (shadow map + cascades uniform buffer), one texture-array set
  (update-after-bind, unused-while-pending, partially bound — core 1.2
  descriptor indexing), one skybox set (written after a device wait).
- Inline uniform blocks became plain uniform buffers (same SPIR-V).

## Why
Lucas, 2026-10-09: shader objects are painful and lock out players. Matches the
feature set already decided for Zeta (`Projects/Zeta/zeta-design.md`): BDA,
dynamic rendering, sync2, extended dynamic state, descriptor indexing, one
persistent descriptor set, zero optional extensions in the critical path.

## Alternatives
- `VK_EXT_extended_dynamic_state3` for dynamic blend: optional extension, the
  thing we're removing. Three blend modes = a few more pipeline rows.
- One pipeline per (state combination) built lazily at draw time: hidden
  caching inside the renderer. 14 rows built up front is simpler.
- Pipeline cache: not added yet; 14 small pipelines build in milliseconds.

## Connections
- `render/vulkan/internal/Vulkan/{Shaders,Resources,TextureTable,device,Instance}.zig`
- Shader table: `render/Shader.zig` (unchanged).
