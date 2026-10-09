# 0011 — vulkan-zig bindings, own GPU memory, no VMA

## What
- Renderer uses Snektron/vulkan-zig (pinned `b496a6a5`, same as gifer/dvui) instead of translate-c of `vulkan.h`.
  `Instance` and `Device` hold heap-allocated wrappers + proxies; command calls go through `device.proxy`.
  The wrappers hold driver function pointers, so they stay valid across a render `.so` hot reload
  (the old `procs.zig` reload rebinding is gone).
- VMA (C++) removed. `GpuMemory.zig`: one `VkDeviceMemory` block per heap — `host` (host-visible,
  coherent, persistently mapped, 256 MiB) for all buffers, `device` (device-local, 768 MiB) for images.
  First-fit over a sorted, fixed-capacity free-range array (1024), coalescing on free; overflow logs and errors.
- `Vulkan` owns the heaps and passes `*GpuMemory`/`*Heaps` into Buffer/Image/Resources — no stored pointers.
- Image barriers are sync2 everywhere.

## Why
Lucas, 2026-10-09: "use vulkan zig binding", "remove VMA!". Handmade rule: few large allocations,
suballocated; no hidden C++ allocator. One `vk` module shared with dvui (U1).

## Alternatives
- One `vkAllocateMemory` per object (gifer): hits `maxMemoryAllocationCount` with streamed planet chunks.
- Growable block list per heap: not needed until a heap overflows; sizes are one constant each.

## Connections
- `render/vulkan/internal/Vulkan/GpuMemory.zig`, `Buffer.zig`, `Image.zig`, `device.zig`, `Instance.zig`
- Supersedes the VMA part of 0010.
