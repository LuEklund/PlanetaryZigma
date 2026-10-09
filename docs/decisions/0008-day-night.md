# 0008 — Day/night cycle

## What
- `shared/src/daynight.zig`: `sunDirection(server_seconds)` (240 s day, axis
  tilted 0.35 rad), `daylight(sun, position)` =
  `smoothstep(-0.10, 0.25, dot(sun, normalize(position)))`, and
  `lightColor(day)` (white by day, dim blue at night).
- The client computes the sun from the **server tick estimate**, so every
  player in a session sees the same sky, writes it into the `DrawList`
  (`sun_direction`, `sky_zenith`, `sky_horizon`, `light_color`), and the
  renderer uses that one vector for the sky shader, the mesh directional light
  and the shadow cascades. The renderer no longer invents a sun from local time
  (`lightDirection` deleted), so sky and lighting cannot desync.
- `assets/shaders/sky.slang`: stylized gradient per the prior ruling —
  `up = normalize(cameraPos)`, `day = smoothstep(-0.10, 0.25, dot(sunDir, up))`,
  zenith/horizon colors for day (per biome row) and night (shader constants),
  a sunset band toward the sun near the horizon, the sun disc from
  `dot(V, sunDir)`, and the existing cubemap faded in as a night-sky backdrop.
  The teleporter-boss red tint now multiplies the biome sky colors on the
  client instead of the whole sky in the shader.
- Each biome row gained `sky_zenith` / `sky_horizon` (C1 tie-in).

## Not done
Optional planet rim (inverted sphere, `pow(1 - dot(N, V), k)`): needs a new
mesh + pipeline state; left out.

## Cost
`DrawList` + `GPUScene` + `scene.slang` grow by two float4s (render contract →
rebuild client, render and server viewer together).
