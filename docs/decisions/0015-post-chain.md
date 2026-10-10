# 0015 — Post chain: bloom, tone, grade, FXAA

**What.**
- After the world passes (into the rgba16f draw image), `renderPostPasses` runs fullscreen triangles from `assets/shaders/post.slang`:
  1. Bloom prefilter: soft-knee threshold, downsample to half resolution.
  2. Gaussian blur in x, then in y (half-res ping-pong).
  3. Composite: scene + bloom × strength, then exposure, then a soft clip (values under 0.8 untouched, brighter ones roll off instead of clipping), then saturation and vignette, into `post_image`.
  4. FXAA (Lottes' compact version) back into the draw image.
- The UI then draws on top, so it never gets blurred or bloomed. The parameters live in `DrawList.Post`, and Options → Graphics has the AA toggle and a bloom slider.
- The passes reuse the world pipeline layout and bindless texture table. Their parameters ride in the push constant's model-matrix slot.
- The chain is skipped until all four post shaders are loaded, so a missing `.spv` can't black out the frame.

**Why.** Lucas wants a RoR2-like look ("nice light", AA). Bloom on HDR highlights plus a soft clip is most of that look for the cost of four cheap passes.

**Alternatives.**
- MSAA: better on geometry edges, but it needs multisampled color and depth images, resolves, and every pipeline rebuilt with a sample count. It can come later if FXAA's softness bothers anyone.
- TAA: needs motion vectors and jitter, and ghosts on our fast-moving particles.
- SMAA: three passes plus lookup textures, which we can't generate (asset rule).

**Validation.** 0 VUIDs on RX 9060 XT. The threshold is 1.1, so only HDR (sun, additive particles) blooms, not white snow.
