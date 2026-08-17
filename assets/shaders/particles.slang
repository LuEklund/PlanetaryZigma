import scene;

struct Emitter {
    float3 origin;
    float spawn_time;
    float3 target;
};

// Mirrors renderer_contract.EffectParams byte for byte.
struct EffectParams {
    uint placement;
    uint motion;
    uint count;
    float lifetime;
    float speed;
    float radius;
    float jitter;
    float arch_height;
    float spin;
    float size_start;
    float size_end;
    uint strands;
    float4 ramp_steps;
    float4 color_ramp[5];
    float stretch;
};

// `params` already points at this effect's row: the CPU pushes base + effect * stride.
struct PushConstant {
    Emitter *emitter_buffer;
    EffectParams *params;
    float elapsed_time;
    uint emitter_count;
};
[[vk::push_constant]]
PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    nointerpolation float age_fraction : TEXCOORD1;
};

static const uint placement_burst = 0;
static const uint placement_line = 1;
static const uint placement_orbit = 2;

static const uint motion_ballistic = 0;
static const uint motion_along_path = 1;

static const float tau = 6.2831853;

static const float2 corners[6] = { float2(-0.5, 0.5), float2(-0.5, -0.5), float2(0.5, 0.5), float2(0.5, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5) };

float hash(float n) {
    return frac(sin(n) * 43758.5453123);
}

uint instancesPerEmitter(EffectParams params) {
    if (params.placement == placement_burst) return params.count;
    if (params.placement == placement_line) return params.count - 1u;
    return params.count - params.strands;
}

float3 burstDirection(float seed, uint index, float3 planet_up) {
    float r0 = hash(float(index) + seed);
    float r1 = hash(r0);
    float z = r0 * 2.0 - 1.0;
    float theta = r1 * tau;
    float2 ring = sqrt(max(0.0, 1.0 - z * z)) * float2(cos(theta), sin(theta));
    float3 direction = float3(ring.x, z, ring.y);
    float outward = dot(direction, planet_up);
    if (outward < 0.2) direction = normalize(direction + planet_up * (0.35 - outward));
    return direction;
}

float speedVariance(float seed, uint index) {
    return 1.0 + (hash(seed + float(index) * 0.7195) * 2.0 - 1.0) * 0.3;
}

// One sided so a varied particle never outlives the emitter that carries it.
float lifetimeOf(EffectParams params, float seed, uint index) {
    return params.lifetime * (1.0 - 0.3 * hash(seed + float(index) * 3.7183));
}

float ageFraction(EffectParams params, float seed, uint index, float age) {
    if (params.lifetime <= 0.0) return 0.0;
    return clamp(age / max(lifetimeOf(params, seed, index), 0.0001), 0.0, 1.0);
}

// arch_height is a fraction of the line's own length, so a long bolt arcs proportionally.
float3 lineNode(EffectParams params, Emitter emitter, float3 direction, float span, float3 planet_up, float seed, float node) {
    float nodes = float(max(params.strands, 1u));
    float fraction = node / nodes;
    float3 on_arc = emitter.origin + (emitter.target - emitter.origin) * fraction + planet_up * (params.arch_height * span * 4.0 * fraction * (1.0 - fraction));
    if (node <= 0.0 || node >= nodes) return on_arc;

    float r0 = hash(node + seed);
    float r1 = hash(r0);
    float r2 = hash(r1);
    float3 raw = normalize(float3(r0 * 2.0 - 1.0, r1 * 2.0 - 1.0, r2 * 2.0 - 1.0));
    return on_arc + (raw - direction * dot(raw, direction)) * params.jitter;
}

float3 linePoint(EffectParams params, Emitter emitter, float3 planet_up, float seed, float t) {
    float3 segment = emitter.target - emitter.origin;
    float span = length(segment);
    float3 direction = segment / max(span, 0.0001);
    float nodes = float(max(params.strands, 1u));
    float node_position = t * nodes;
    float node = floor(node_position);
    return lerp(lineNode(params, emitter, direction, span, planet_up, seed, node), lineNode(params, emitter, direction, span, planet_up, seed, node + 1.0),
        frac(node_position));
}

float3 orbitPoint(EffectParams params, Emitter emitter, float3 planet_up, float seed, float animation_time, float t) {
    float3 side = normalize(cross(planet_up, float3(0.0, 0.0, 1.0) + planet_up * 0.5));
    float3 forward = cross(planet_up, side);

    float height = params.arch_height * (0.7 + hash(seed) * 0.7);
    float ring_radius = params.radius * (0.6 + hash(hash(seed)) * 0.8);
    float spin = params.spin * (hash(seed + 4.1379) < 0.5 ? -1.0 : 1.0) * (0.6 + hash(seed + 5.2841) * 0.8);

    float offset_angle = hash(seed + 2.1713) * tau;
    float3 offset = (side * cos(offset_angle) + forward * sin(offset_angle)) * params.jitter;

    float angle = seed * tau + t * params.speed * tau + animation_time * spin;
    float sway = sin(animation_time * 1.6 + seed * tau + t * 4.5) * 0.5 * t;
    float radius = ring_radius * sin(t * 2.7 + 0.25) + sway;

    return emitter.origin + offset + planet_up * (t * height) + (side * cos(angle) + forward * sin(angle)) * radius;
}

float3 pathPoint(EffectParams params, Emitter emitter, float3 planet_up, float seed, float animation_time, float t) {
    if (params.placement == placement_line) return linePoint(params, emitter, planet_up, seed, t);
    return orbitPoint(params, emitter, planet_up, seed, animation_time, t);
}

float4 colorRamp(EffectParams params, float intensity) {
    float4 color = params.color_ramp[0];
    color = intensity < params.ramp_steps.x ? color : params.color_ramp[1];
    color = intensity < params.ramp_steps.y ? color : params.color_ramp[2];
    color = intensity < params.ramp_steps.z ? color : params.color_ramp[3];
    return intensity < params.ramp_steps.w ? color : params.color_ramp[4];
}

[shader("vertex")]
VertexOutput particles_vert(uint vertex_index: SV_VertexID, uint instance_index: SV_InstanceID) {
    EffectParams params = push_constant.params[0];
    uint instances = instancesPerEmitter(params);
    uint emitter_index = instance_index / instances;
    uint local_index = instance_index % instances;
    Emitter emitter = push_constant.emitter_buffer[emitter_index];

    float age = push_constant.elapsed_time - emitter.spawn_time;
    float seed = frac(emitter.spawn_time);
    float3 planet_up = normalize(emitter.origin);
    float2 corner = corners[vertex_index];
    float animation_time = params.motion == motion_along_path ? scene_data.time : 0.0;

    VertexOutput output;
    if (params.placement == placement_burst) {
        float3 direction = burstDirection(seed, local_index, planet_up);
        float3 start = emitter.origin + planet_up * params.arch_height + direction * params.radius;
        float3 travel = params.motion == motion_ballistic ? direction * params.speed * speedVariance(seed, local_index) * age : float3(0.0, 0.0, 0.0);
        float3 position = start + travel;

        output.age_fraction = ageFraction(params, seed, local_index, age);
        float size = lerp(params.size_start, params.size_end, output.age_fraction);

        float3 forward = normalize(scene_data.camera_position - position);
        float3 right = normalize(cross(scene_data.camera_up.xyz, forward));
        float3 up = cross(forward, right);
        float3 world_position;
        if (params.stretch > 0.0) {
            float3 heading = emitter.target - emitter.origin;
            float3 projected = heading - forward * dot(heading, forward);
            float projected_length = length(projected);
            float3 long_axis = projected_length > 0.001 ? projected / projected_length : right;
            float3 short_axis = cross(forward, long_axis);
            world_position = position + (long_axis * corner.x * params.stretch + short_axis * corner.y) * size;
        } else {
            world_position = position + (right * corner.x + up * corner.y) * size;
        }

        output.position = mul(scene_data.proj_view, float4(world_position, 1.0));
        output.uv = float2(corner.x + 0.5, 0.5 - corner.y);
        return output;
    }

    uint chains = params.placement == placement_orbit ? max(params.strands, 1u) : 1u;
    uint segments = params.count / chains - 1u;
    uint chain_index = local_index / segments;
    uint segment_index = local_index % segments;
    float chain_seed = chains == 1u ? seed : hash(seed + float(chain_index));

    float t0 = float(segment_index) / float(segments);
    float t1 = float(segment_index + 1) / float(segments);
    float t = corner.x < 0.0 ? t0 : t1;
    float3 center = pathPoint(params, emitter, planet_up, chain_seed, animation_time, t);
    float3 ahead = pathPoint(params, emitter, planet_up, chain_seed, animation_time, t + 0.01);
    float3 behind = pathPoint(params, emitter, planet_up, chain_seed, animation_time, t - 0.01);

    output.age_fraction = ageFraction(params, seed, chain_index, age);
    float size = lerp(params.size_start, params.size_end, output.age_fraction);
    float width = size * (0.35 + 1.3 * sin(t * 3.1415926));

    float3 view_direction = normalize(scene_data.camera_position - center);
    float3 across = cross(ahead - behind, view_direction);
    float3 world_position = center + across / max(length(across), 0.0001) * corner.y * width;

    output.position = mul(scene_data.proj_view, float4(world_position, 1.0));
    output.uv = float2(0.5, corner.y + 0.5);
    return output;
}

[shader("fragment")]
float4 particles_frag(VertexOutput input) : SV_Target {
    EffectParams params = push_constant.params[0];
    float core = clamp(1.0 - length(input.uv * 2.0 - 1.0), 0.0, 1.0);
    float aged = 1.0 - input.age_fraction;
    float intensity = clamp(sqrt(core) * 0.75 + aged * 0.25, 0.0, 1.0);
    float4 color = colorRamp(params, intensity);
    float fade = smoothstep(0.0, 0.25, aged);
    return float4(color.rgb, core * core * color.a * fade);
}
