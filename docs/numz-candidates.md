# numz candidates

Generic math that grew in this repo and probably belongs in numz (Lucas's repo — he moves it).
Staged in `shared/src/math.zig` until then.

- `projectOnPlane(vector, normal)` — `vector - normal * dot(vector, normal)`.
- `approach(value, target, step)` — move a scalar toward a target by at most `step`.
- `worldToScreen(view_proj, position, screen_size) ?[2]f32` — today in `client/src/system/hud/style.zig`.
