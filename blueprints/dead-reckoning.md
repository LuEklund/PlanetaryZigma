# Dead reckoning for PlanetaryZigma — draft

Working notes on moving PlanetaryZigma's entity replication from per-tick snapshots to **dead reckoning**: send "position + velocity" occasionally, let the client extrapolate the rest. Rough, will be refined as it gets implemented.



## Where we are now

The server sends a position snapshot for **every entity, every tick** (position + rotation), and the client hard-assigns it on arrival — straight teleport, no interpolation, no shared clock. Client and server each run their own fixed step and the two clocks are unrelated.

Two problems with this:
- **It's jittery** — the client jumps to each snapshot instead of moving smoothly between them, and any lost/late packet is a visible pop.
- **It doesn't scale** — outgoing traffic is `entities × tickrate`, sent whether or not anything actually moved. A field of idle items costs exactly as much as a battle.

## Why move to dead reckoning

Instead of a position every tick, the server sends an update only when an entity moves in a way the client couldn't have predicted on its own. The client fills the gaps itself, so idle and straight-line entities go quiet — outgoing traffic tracks *actual movement* instead of entity count × tickrate.

Per-packet size (current, unoptimized — every value is full `f32`):

| Field | Snapshot `UpdateTransform` | Motion `UpdateMotion` |
|---|---|---|
| packet tag (`u16`) | 2 | 2 |
| `id` (`u32`) | 4 | 4 |
| `position` | 6 (`3×f16`) | 12 (`3×f32`) |
| `velocity` | — | 12 (`3×f32`) |
| `rotation` | 8 (`4×f16`) | 16 (`4×f32`) |
| `tick` (`u32`) | — | 4 |
| **total** | **20 B** | **50 B** |

So a single `UpdateMotion` is **2.5× bigger** than a single snapshot. The win isn't packet size — it's *how many you send*:

| | Snapshots (now) | `UpdateMotion`s |
|---|---|---|
| Sent when | every entity, every tick | only when the prediction drifts past a threshold |
| Idle / constant-velocity entity | full packet every tick | **nothing** |
| Packets/s — 100 entities @ 60Hz | 6,000 (fixed) | a few hundred (only the movers) |
| **Bandwidth** — 100 entities @ 60Hz | ~120 KB/s | ~15 KB/s |
| Scales with | entities × tickrate | actual movement |
| Client smoothness | snaps | interpolates + extrapolates |

The idea the whole design rests on: the wire carries *output the client can evaluate*, not *intent the client has to simulate*. The client runs no gameplay logic; the server stays authoritative and hot-reloadable.

---

## Step 1 — Define the `UpdateMotion` packet

**WHAT:** Add the packet that replaces the snapshot — it's just a packet the server sends to the client.

```zig
pub const UpdateMotion = struct {
    id: u32,
    position: nz.Vec3(f32),
    velocity: nz.Vec3(f32),
    rotation: nz.Vec4(f32),
    tick: u32,
};
```

The fields:
- `id` — which entity this `UpdateMotion` describes.
- `position` — where the entity is at `tick`.
- `velocity` — units per second.
- `rotation` — orientation as a quaternion (x, y, z, w); sent whole. The client doesn't extrapolate it like position — it slerps toward the latest one (Step 7).
- `tick` — which server tick this was sampled at.

**WHY:**  The client finds where the entity is now with `position + velocity × time_since_tick`. That's the whole model — everything else is *when* to send it and *how* to read it.

**GOTCHA:** Full `f32`, not `f16`. The fitter below measures sub-decimeter drift; `f16` position noise would trip the epsilon by itself.

---

## Step 2 — Server tick is the clock unit

**WHAT:** Mostly just a tick counter. If the server doesn't already have one, add a `u32` that increments by 1 every simulation loop — this is what gets sent as `UpdateMotion.tick`. That loop runs on a fixed interval; call that interval `tick_seconds` (e.g. `0.016` at 60Hz) — it's just how many seconds one tick lasts.

Also send the current tick to a **newly connected player**: add a `tick: u32` to the acknowledge packet and fill it with the server tick at connect. That hands the client the server's time the moment it joins and keeps `UpdateMotion` as pure motion data. After that, the client just tracks the newest tick it sees.

**WHY:** A tick number on its own means nothing to the client — it has to turn "tick 4012" into an actual point in time, which it does by multiplying by `tick_seconds`. So both sides must agree on `tick_seconds`: if the server bumps its tick every `0.016s`, the client has to assume `0.016s` per tick too, or it places everything at the wrong moment. That one shared constant is the only thing linking the server's clock to the client's.

---

## Step 3 — Naive `UpdateMotion`: emit every tick

**WHAT:** Wire the packet up the dumbest way that works: every tick, for every dynamic entity, send an `UpdateMotion` with its current position and rotation — velocity left at zero, no math. The client just teleports to `UpdateMotion.position`. Same behaviour as the old teleport position version, only now it flows through `UpdateMotion`.

Server, per dynamic entity each tick:

```zig
sendMotion(.{
    .id = entity.id,
    .position = entity.position,
    .velocity = @splat(0), // not computed yet — Step 4
    .rotation = entity.rotation,
    .tick = tick,
});
```

Client, on receiving a `UpdateMotion`:

```zig
entity.position = motion.position; // teleport
entity.rotation = motion.rotation;
```

**WHY:** Prove the new pipe end-to-end before adding the two hard parts (the fitter and the evaluator). If this looks identical to the snapshots you started with, the wire format and plumbing are correct and isolated from the smartness.


---

## Step 4 — Server fitter: only send on drift

**WHAT:** Only send a new `UpdateMotion` when the entity has drifted off what its last `UpdateMotion` predicted (instead of every tick). The only per-entity state you need is the last `UpdateMotion` you sent — so just keep a map of entity id → its last `UpdateMotion`, no wrapper struct:

```zig
last_motions: std.AutoHashMap(u32, UpdateMotion),
```

Each tick, per dynamic entity:

```zig
const entry = try last_motions.getOrPut(entity.id);
const last_motion = entry.value_ptr;

// first time we see this entity: store its current state and send it reliably
if (!entry.found_existing) {
    last_motion.* = .{ .id = entity.id, .position = position, .velocity = entity.velocity, .rotation = rotation, .tick = tick };
    // queue to send, reliable
    continue;
}

// still on the server: re-run the exact prediction the client is doing from the last UpdateMotion we sent it
const elapsed = @as(f32, @floatFromInt(tick - last_motion.tick)) * tick_seconds;
const predicted = last_motion.position + nz.vec.scale(last_motion.velocity, elapsed);
const position_drift = nz.vec.length(position - predicted);
const rotation_drift = 1.0 - @abs(nz.vec.dot(rotation, last_motion.rotation));

// only replace (and send) the UpdateMotion when reality has wandered too far from the prediction
if (position_drift > position_epsilon or rotation_drift > rotation_epsilon) {
    last_motion.* = .{ .id = entity.id, .position = position, .velocity = entity.velocity, .rotation = rotation, .tick = tick };
    // queue to send, unreliable
}
```

`position_epsilon ≈ 0.25`, `rotation_epsilon ≈ 0.01`. Send `UpdateMotion`s unreliable. A newly-seen entity gets one `UpdateMotion` immediately, sent reliably, so the client has a starting point.

**WHY:** This is the bandwidth win and the name of the whole technique. You stop sending an entity the instant the client could have predicted its position itself. A unit moving in a straight line emits ~one `UpdateMotion` and goes silent. A resting object emits nothing.

**GOTCHA:** Compare against the *predicted* position, not the last *sent* position — otherwise a constant-velocity object re-emits every tick.

---

## Step 5 — Client clock sync

**WHAT:** `UpdateMotion`s are stamped with *server* ticks, but to evaluate one the client needs to know "what server tick is it *right now*?" So it keeps a running estimate of the server's clock. Four pieces of state, each with a job:

- `server_tick_estimate: f32` — the client's best guess of the current server tick (fractional, for computational reasons).
- `server_tick_latest: u32` — the highest tick the client has received in any packet. *Why:* it's the moving target the clock corrects toward, so the client's own clock can't slowly drift off the server.
- `render_delay_ticks` — how far *behind* that latest tick the client deliberately renders. *Why:* the small lag means there's almost always a newer `UpdateMotion` to move toward (interpolate) instead of having to guess past the last one (extrapolate, which overshoots on turns). Start at `1`.
- `clock_synced: bool` — whether the estimate has been seeded yet.

Seed them from the connect acknowledgement (Step 2), which carries the server's current tick:

```zig
server_tick_estimate = @as(f32, @floatFromInt(acknowledge.tick)) - render_delay_ticks;
server_tick_latest = acknowledge.tick;
clock_synced = true;
```

Update `server_tick_latest` on every `UpdateMotion` received: `server_tick_latest = @max(server_tick_latest, motion.tick)` (`@max` because unreliable `UpdateMotion`s can arrive out of order — an old straggler must not drag it backward).

So far `server_tick_estimate` only has its seed value. But it's the clock the evaluator reads *every frame* to know "what server time is it now," and the client renders constantly while server updates arrive only now and then. So the clock has to keep moving on its own between updates. Each frame:

```zig
server_tick_estimate += delta_time / tick_seconds;
```

**Advance** — move the clock forward by however many ticks of real time passed this frame. This is what makes motion smooth: the clock keeps moving between packets.

If that were perfect we'd be done. It isn't: your machine's clock runs slightly differently from the server's, and a frame hitch (alt-tab, a load spike) makes that line under-count. Those tiny errors **pile up with no way back** — after a few minutes the client would be rendering everything noticeably in the past or future, and nothing would ever pull it straight. So each frame also figure out where the clock *should* be:

```zig
const target = @as(f32, @floatFromInt(server_tick_latest)) - render_delay_ticks;
```

**Target** — where the clock should be right now: take the newest tick the server sent us (`server_tick_latest`) and sit a fixed amount behind it. That fixed amount is `render_delay_ticks` — our own constant (`= 1`).

```zig
server_tick_estimate += (target - server_tick_estimate) * clock_correction_rate;
```

**Correction** — close a fraction of the gap to that target. `(target - server_tick_estimate)` is the *gap*; `clock_correction_rate` (≈ `0.1`) is how much of it to close each frame.

> **Example — plug numbers into the correction line.** Setup:
>
> ```zig
> server_tick_latest = 1000;  // newest tick received from the server
> render_delay_ticks = 1;     // our constant
> target = server_tick_latest - render_delay_ticks;  // 999
> clock_correction_rate = 0.1;
> ```
>
> Then it only depends on where `server_tick_estimate` sits (`target = 999` from above):
>
> ```zig
> server_tick_estimate += (target - server_tick_estimate) * clock_correction_rate;
>
> // in sync
> server_tick_estimate = 999;
> server_tick_estimate += (999 - 999) * 0.1;   // += 0      → 999    (nothing to do)
>
> // behind — a frame hitch under-counted
> server_tick_estimate = 996;
> server_tick_estimate += (999 - 996) * 0.1;   // += +0.3   → 996.3  (catching up)
>
> // ahead — a stall let it overshoot
> server_tick_estimate = 1002;
> server_tick_estimate += (999 - 1002) * 0.1;  // += -0.3   → 1001.7 (easing back)
> ```

Positive gap → forward, negative → back, zero → untouched. Always 10% of what's left, so it eases in instead of snapping.

**On "why set it at connect and again every frame":** the connect seed just sets the *starting* value once — like setting a clock when you first power it on. The per-frame advance + correction are the ongoing run: advance it because time passes, correct it because your advance isn't perfect. They don't redo the seed; they keep the clock the seed started.

**WHY:** The client renders at `server_tick_estimate`, which it holds *behind* the newest server tick by `render_delay_ticks`. That delay is what lets the client interpolate between two `UpdateMotion`s it already has, instead of extrapolating past the newest one. The estimate free-runs at real time (`+= delta_time/tick_seconds`) and is gently pulled toward the true server tick so it neither drifts nor snaps. Because of that correction term it can't *permanently* desync — it continuously chases the newest tick.

**GOTCHA:** Keep the render_delay_ticks small — about 1–2 ticks (≈17–34ms at 60Hz). Too small and the client runs out of data between updates and has to extrapolate → jitter; too big and you've just added that much input latency for nothing.

---

## Step 6 — Client evaluator (with extrapolation cap)

**WHAT:** Back in Step 3 the client teleported each entity straight to `UpdateMotion.position` the instant an update arrived — instant, jumpy positions. Replace that with an **evaluator**: a function that runs every frame and *computes* where each entity is from its latest `UpdateMotion` plus the clock, so it glides between updates instead of jumping. (It's called an evaluator because it just plugs the current time into the motion and reads off a position — it never simulates.)

Two changes from Step 3:

1. **On receive, store instead of apply.** In Step 3 the client teleported when an `UpdateMotion` arrived (`entity.position = motion.position`). Now it just saves the update on the entity (add a field `entity.update_motion: ?UpdateMotion`) and applies nothing:

```zig
entity.update_motion = received; // the evaluator below applies it, every frame
```

2. **The evaluator** runs every frame. For each entity it reads its stored `UpdateMotion` and moves the position forward by how much time has passed since that update: `position + velocity × age`, where `age` is that gap converted to seconds: `(server_tick_estimate − entity.update_motion.tick) × tick_seconds`.

`age` is also clamped to `max_extrapolation_seconds` (≈ `0.25`) so a stale update can't fly the entity off forever — see the GOTCHA.

```zig
const server_time = server_tick_estimate * tick_seconds;
for (entities) |*entity| {
    const motion = entity.update_motion orelse continue;
    const motion_time = @as(f32, @floatFromInt(motion.tick)) * tick_seconds;
    const age = @min(server_time - motion_time, max_extrapolation_seconds);
    const target = motion.position + nz.vec.scale(motion.velocity, age);
    entity.position = target;
    entity.rotation = motion.rotation; // instant for now; smoothed in Step 7
}
```

**WHY:** The client will only do `UpdateMotion`s + the clock. No physics, no input integration, no gameplay. `max_extrapolation_seconds` caps how far a stale `UpdateMotion` can run.

**GOTCHA** without the max_extrapolation_seconds, `target = position + velocity * age` runs forever. If a moving entity stops getting `UpdateMotion`s (it left view, packet loss, or it came to rest with a stale non-zero velocity), `age` grows without bound and it flies across the map. The cap holds it at the last believable point until a fresh `UpdateMotion` or a zero-velocity rest `UpdateMotion` (Step 8) corrects it. 

How big the max_extrapolation_seconds (or whether to at all) depends on the game: bigger lets entities coast longer through brief gaps (more overshoot), smaller pulls them up sooner. You can skip the cap and instead rely on the server always sending a stop a rest update, so velocity never goes stale. Or look into **curves** — the keyframed approach (Step 9, PA's ChronoCam in Sources) carries the whole path *including its end*, so there's no open-ended velocity to fly off in the first place.

---

## Step 7 — Smoothing (position & rotation)

Step 6 moves entities smoothly *between* updates, but the moment a new `UpdateMotion` arrives there are two snaps: the position jumps to the corrected spot (your extrapolation was a little off), and the rotation clicks to the new orientation (it's been snapped since Step 3). Step 7 eases both out — no new behaviour, just removing those two pops.

**WHAT — position:** When a new `UpdateMotion` lands, don't jump straight to its `target`; carry the leftover error and decay it out over a few frames. This needs **two new fields on the client entity**, both used in the snippet below.

- `entity.smoothed_motion_tick: u32` — the tick of the last update we smoothed. If it matches the incoming `motion.tick` we're on the same update / same position → no new transition needed. If it differs → new update → snapshot the gap.
- `entity.position_error: Vec3` — if we smooth, we take the current entity position and subtract the new incoming position, so we can smooth out those two. Shrink it to zero over the next frames.

With those in place, the snapshot runs once per new update:

```zig
// once per new update: snapshot how far off we currently are
if (motion.tick != entity.smoothed_motion_tick) {
    entity.position_error = entity.position - target;
    entity.smoothed_motion_tick = motion.tick;
}
```

The `position_error` we just captured needs to shrink toward zero a bit each frame, so the entity glides onto the true path instead of holding the offset forever. That per-frame shrink factor is `error_decay`:

```zig
const error_decay = std.math.pow(f32, error_decay_per_second, delta_time);
entity.position_error = nz.vec.scale(entity.position_error, error_decay);
```

The `pow` keeps it frame-rate independent: `error_decay_per_second` is how much error is left after one whole second, and `pow(rate, delta_time)` scales that to one frame's slice. So 30fps and 60fps shrink by the same amount per real second.

> **Example — same decay, two frame rates.** `error_decay_per_second = 0.01` (1% of the error left after a whole second):
>
> ```zig
> error_decay_per_second = 0.01;
>
> // 60fps — short frame, small slice of the second
> error_decay = pow(0.01, 0.016) ≈ 0.93;   // 7% removed this frame
>
> // 30fps — longer frame, bigger slice
> error_decay = pow(0.01, 0.033) ≈ 0.86;   // 14% removed this frame
> ```
>
> Bigger frame → bigger per-frame shrink, so both rates remove the same total over one real second.

**Tuning `error_decay_per_second`:**
- **Smaller** → error collapses fast → snappy, but barely softens the pop.
- **Larger** (toward `1.0`) → bleeds out slowly → very smooth, but the entity floats behind its true position (laggy).
- `0.0` = instant snap, `1.0` = never corrects. Keep it near the small end.

Start at `1e-5` and adjust by feel: lower if smoothing feels mushy, raise if pops still show.

**Finally, draw it.** Back in Step 6 the evaluator ended with `entity.position = target` — **remove that line**, or you'll assign position twice. Replace it with the offset draw so the entity sits at `target` plus its still-decaying error:

```zig
entity.position = target + entity.position_error;
```



**WHAT — rotation:** Same idea, but rotation isn't extrapolated — just slerp the current orientation toward the latest `UpdateMotion`'s rotation each frame instead of snapping. Three pieces, all new here:

- `target_rotation` — the latest `UpdateMotion.rotation` as a quaternion: the orientation we're easing toward.
- `rotation_smooth_per_second` — the knob, same idea as `error_decay_per_second`: fraction of the rotation gap still left after one second.
- `rotation_decay` — that knob converted to this frame's slice with `pow(rate, delta_time)`, exactly like `error_decay`.

`slerp(a, b, fraction)` moves `fraction` of the way from `a` to `b`. We want to *close* a fraction of the gap each frame, so we slerp by `1.0 - rotation_decay` (decay is how much gap is *left*, so `1 - decay` is how much we close):

```zig
const target_rotation = nz.Quat(f32).fromVec(motion.rotation);
const rotation_decay = std.math.pow(f32, rotation_smooth_per_second, delta_time);
entity.rotation = entity.rotation.slerp(target_rotation, 1.0 - rotation_decay);
```

**Tuning:** Lower `rotation_smooth_per_second` → snappier (toward an instant snap); higher (toward 1) → floatier turns. Rotation smoothing is client-only — it costs zero bandwidth.

---

## Step 8 — To add / improve

Not tried yet — quick notes on where this would go next.

- **Resting bodies:** on sleep / near-zero velocity, emit one zero-velocity `UpdateMotion` so the client stops extrapolating. Cheaper and more correct than the cap.
- **10Hz sim:** drop `tick_seconds` to `0.1` (PA's 10fps-sim / 60fps-client split); bump `render_delay_ticks` to keep ~100–150ms delay. ([ChronoCam](https://www.forrestthewoods.com/blog/tech_of_planetary_annihilation_chrono_cam/))
- **Far-side cull:** skip `UpdateMotion`s for entities behind the planet, per-client. Needs a freeze update on near→far (else fly-away). Only worth it at high entity counts. ([Unreal dormancy](https://dev.epicgames.com/documentation/en-us/unreal-engine/actor-network-dormancy-in-unreal-engine))
- **Curves (the real upgrade):** we don't do curves — one forward ray per entity. Storing a timeline of keyframes instead (true ChronoCam) buys replay / spectator rewind / lag-comp by evaluating any *past* time. Live motion looks identical, so only add it for time travel. ([ChronoCam](https://www.forrestthewoods.com/blog/tech_of_planetary_annihilation_chrono_cam/))
- **Fog-of-war cull:** never send `UpdateMotion`s for units a player shouldn't see → client can't wallhack. (Same per-client send-filter as far-side cull.)

---

## Sources

**Read:**

- **ChronoCam** — Forrest Smith, "The Tech of Planetary Annihilation: ChronoCam" — https://www.forrestthewoods.com/blog/tech_of_planetary_annihilation_chrono_cam/ — the curve thesis (the keyframed version), 10/60 sim/client split, per-client culling.
- **Gambetta — Client-Server Game Architecture** — https://gabrielgambetta.com/client-server-game-architecture.html — entity interpolation, the client as a renderer of authoritative state.

**Further / referenced:**

- **Aronson** — "Dead Reckoning: Latency Hiding for Networked Games" — https://www.gamedeveloper.com/programming/dead-reckoning-latency-hiding-for-networked-games — emit when the dead-reckoned position exceeds a threshold (Step 4).
- **Murphy** — "Believable Dead Reckoning for Networked Games", *Game Engine Gems 2* — https://www.researchgate.net/publication/293809946_Believable_Dead_Reckoning_for_Networked_Games — projective velocity blending / convergence (Step 7).
- **Valve — Source Multiplayer Networking** — https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking — and **Interpolation** — https://developer.valvesoftware.com/wiki/Interpolation — the interpolation delay / `cl_interp` model (Step 5).

- **Gaffer — Snapshot Interpolation** — https://gafferongames.com/post/snapshot_interpolation/
- **Gaffer — State Synchronization** — https://gafferongames.com/post/state_synchronization/
- **Tribes networking model** — https://www.gamedevs.org/uploads/tribes-networking-model.pdf — prioritized relevance (Step 8).
- **Unreal — Actor Network Dormancy** — https://dev.epicgames.com/documentation/en-us/unreal-engine/actor-network-dormancy-in-unreal-engine — far-side culling productionized (Step 8).
