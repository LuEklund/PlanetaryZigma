struct SceneData {
    float4x4 proj_view;
    float4x4 inverse_proj_rotation;
    float3 global_light_direction;
    float time;
    float4 camera_position;
    float4 light_color;
    float4 camera_up;
};
[[vk::binding(0, 0)]] ConstantBuffer<SceneData> scene_data;

struct Emitter {
    float3 origin;
    float spawn_time;
    float3 target;
};

struct PushConstant {
    Emitter *emitter_buffer;
    float elapsed_time;
    uint particle_count;
    uint emitter_count;
    float duration;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
};

static const float3 edge_color = float3(0.431, 0.627, 1.0);
static const float3 center_color = float3(1.0, 1.0, 1.0);

static const float2 corners[6] = {
    float2(-0.5, 0.5), float2(-0.5, -0.5), float2(0.5, 0.5),
    float2(0.5, 0.5), float2(-0.5, -0.5), float2(0.5, -0.5)
};

static const float jitter_nodes = 8.0;

float hash(float n) { return frac(sin(n) * 43758.5453123); }

static const float thickness = 0.55;

float3 nodePosition(float node, float3 origin, float3 segment, float3 direction, float3 planet_up, float arch_height, float seed) {
    float t = node / jitter_nodes;
    float3 on_arc = origin + segment * t + planet_up * (arch_height * 4.0 * t * (1.0 - t));
    if (node <= 0.0 || node >= jitter_nodes) return on_arc;

    float r0 = hash(node + seed);
    float r1 = hash(r0);
    float r2 = hash(r1);
    float3 raw = normalize(float3(r0 * 2.0 - 1.0, r1 * 2.0 - 1.0, r2 * 2.0 - 1.0));
    return on_arc + (raw - direction * dot(raw, direction)) * 0.6;
}

float3 boltPoint(float t, float3 origin, float3 segment, float3 direction, float3 planet_up, float arch_height, float seed) {
    float node_position = t * jitter_nodes;
    float node = floor(node_position);
    return lerp(
        nodePosition(node, origin, segment, direction, planet_up, arch_height, seed),
        nodePosition(node + 1.0, origin, segment, direction, planet_up, arch_height, seed),
        frac(node_position)
    );
}

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID, uint instance_index: SV_InstanceID) {
    uint segment_count = push_constant.particle_count - 1;
    uint segment_index = instance_index % segment_count;
    uint emitter_index = instance_index / segment_count;
    Emitter emitter = push_constant.emitter_buffer[emitter_index];

    float age = push_constant.elapsed_time - emitter.spawn_time;
    float seed = frac(emitter.spawn_time);

    float3 segment = emitter.target - emitter.origin;
    float length_along = length(segment);
    float3 direction = segment / max(length_along, 0.0001);
    float3 planet_up = normalize(emitter.origin);
    float arch_height = length_along * 0.35;

    float3 start = boltPoint(float(segment_index) / float(segment_count), emitter.origin, segment, direction, planet_up, arch_height, seed);
    float3 end = boltPoint(float(segment_index + 1) / float(segment_count), emitter.origin, segment, direction, planet_up, arch_height, seed);

    float lifetime = (0.733 + hash(seed) * 0.267) * push_constant.duration;
    float life = clamp(1.0 - age / lifetime, 0.0, 1.0);

    float2 corner = corners[vertex_index];
    float3 center = lerp(start, end, corner.x + 0.5);
    float3 forward = normalize(scene_data.camera_position.xyz - center);
    float3 across = cross(end - start, forward);
    float3 world_position = center + across / max(length(across), 0.0001) * corner.y * thickness * life;

    VertexOutput output;
    output.position = mul(scene_data.proj_view, float4(world_position, 1.0));
    output.color = float4(1.0, 1.0, 1.0, 1.0);
    output.uv = float2(0.5, corner.y + 0.5);
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    float core = clamp(1.0 - length(input.uv * 2.0 - 1.0), 0.0, 1.0);
    float4 texel = float4(lerp(edge_color, center_color, sqrt(core)), core * core) * input.color;
    return float4(texel.rgb, texel.a * 0.45);
}
