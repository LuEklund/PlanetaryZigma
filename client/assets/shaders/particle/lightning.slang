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

[[vk::binding(0, 1)]] Sampler2D textures[256];

struct Emitter {
    float3 origin;
    float spawn_time;
    float3 target;
    uint slot;
};

struct Particle {
    float3 position;
    float scale;
    float3 velocity;
    float age;
    float4 color;
    float seed;
    float lifetime;
    float2 padding;
};

struct PushConstant {
    Particle *particle_buffer;
    Emitter *emitter_buffer;
    float elapsed_time;
    float delta_time;
    uint particle_count;
    uint particle_stride;
    uint emitter_count;
    uint texture_index;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
    nointerpolation uint texture_index : TEXCOORD1;
};

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

    float3 raw = normalize(float3(
        hash(node + seed * 31.0) * 2.0 - 1.0,
        hash(node * 5.1 + seed * 17.0) * 2.0 - 1.0,
        hash(node * 9.7 + seed * 73.0) * 2.0 - 1.0
    ));
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
VertexOutput lightning_vert(uint vertex_index: SV_VertexID, uint instance_index: SV_InstanceID) {
    uint segment_count = push_constant.particle_count - 1;
    uint segment_index = instance_index % segment_count;
    uint emitter_index = instance_index / segment_count;
    Emitter emitter = push_constant.emitter_buffer[emitter_index];

    float age = push_constant.elapsed_time - emitter.spawn_time;
    float seed = frac(emitter.spawn_time * 7.13);

    float3 segment = emitter.target - emitter.origin;
    float length_along = length(segment);
    float3 direction = segment / max(length_along, 0.0001);
    float3 planet_up = normalize(emitter.origin);
    float arch_height = length_along * 0.35;

    float3 start = boltPoint(float(segment_index) / float(segment_count), emitter.origin, segment, direction, planet_up, arch_height, seed);
    float3 end = boltPoint(float(segment_index + 1) / float(segment_count), emitter.origin, segment, direction, planet_up, arch_height, seed);

    float lifetime = 0.22 + hash(seed * 3.0) * 0.08;
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
    output.texture_index = push_constant.texture_index;
    return output;
}

[shader("fragment")]
float4 lightning_frag(VertexOutput input) : SV_Target {
    float4 texel = textures[input.texture_index].Sample(input.uv) * input.color;
    return float4(texel.rgb, texel.a * 0.45);
}
