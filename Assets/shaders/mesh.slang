import scene;

[[vk::binding(0, 1)]]
Sampler2D textures[256];

[[vk::binding(0, 2)]]
Sampler2DShadow shadow_map;

struct CascadeData {
    float4x4 light_view_proj[3];
    float4 splits;
};
[[vk::binding(1, 2)]]
ConstantBuffer<CascadeData> cascade_data;

struct Vertex {
    float3 position;
    float uv_x;
    float3 normal;
    float uv_y;
    float4 color;
};

struct SkinnedVertex {
    float3 position;
    float uv_x;
    float3 normal;
    float uv_y;
    float4 color;
    int4 joint_indices;
    float4 joint_weights;
};

struct PushConstant {
    float4x4 model_matrix;
    Vertex *vertex_buffer;
    float4x4 *joint_matrices;
    uint texture_index;
};
[[vk::push_constant]]
PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL0;
    float3 world_position : TEXCOORD1;
};

[shader("vertex")]
float4 highlight_static_vert(uint vertex_index: SV_VertexID) : SV_Position {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];
    return mul(scene_data.proj_view, mul(push_constant.model_matrix, float4(vertex.position, 1.0)));
}
[shader("vertex")]
float4 highlight_skinned_vert(uint vertex_index: SV_VertexID) : SV_Position {
    SkinnedVertex *skinned_buffer = (SkinnedVertex *)push_constant.vertex_buffer;
    SkinnedVertex vertex = skinned_buffer[vertex_index];
    float4 local = float4(vertex.position, 1.0);
    float4x4 skin_matrix = vertex.joint_weights.x * push_constant.joint_matrices[vertex.joint_indices.x] +
                           vertex.joint_weights.y * push_constant.joint_matrices[vertex.joint_indices.y] +
                           vertex.joint_weights.z * push_constant.joint_matrices[vertex.joint_indices.z] +
                           vertex.joint_weights.w * push_constant.joint_matrices[vertex.joint_indices.w];
    return mul(scene_data.proj_view, mul(push_constant.model_matrix, local));
}
[shader("fragment")]
float4 highlight_frag() : SV_Target {
    return float4(1, 1, 1, 1);
}

[shader("vertex")]
VertexOutput static_vert(uint vertex_index: SV_VertexID) {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];
    float4 world_position = mul(push_constant.model_matrix, float4(vertex.position, 1.0));

    VertexOutput output;
    output.position = mul(scene_data.proj_view, world_position);
    output.color = vertex.color;
    output.uv = float2(vertex.uv_x, vertex.uv_y);
    output.normal = mul(push_constant.model_matrix, float4(vertex.normal, 0.0)).xyz;
    output.world_position = world_position.xyz;
    return output;
}

[shader("vertex")]
VertexOutput skinned_vert(uint vertex_index: SV_VertexID) {
    SkinnedVertex *skinned_buffer = (SkinnedVertex *)push_constant.vertex_buffer;
    SkinnedVertex vertex = skinned_buffer[vertex_index];

    float4x4 skin_matrix = vertex.joint_weights.x * push_constant.joint_matrices[vertex.joint_indices.x] +
                           vertex.joint_weights.y * push_constant.joint_matrices[vertex.joint_indices.y] +
                           vertex.joint_weights.z * push_constant.joint_matrices[vertex.joint_indices.z] +
                           vertex.joint_weights.w * push_constant.joint_matrices[vertex.joint_indices.w];

    float4 world_position = mul(push_constant.model_matrix, mul(skin_matrix, float4(vertex.position, 1.0)));

    VertexOutput output;
    output.position = mul(scene_data.proj_view, world_position);
    output.color = vertex.color;
    output.uv = float2(vertex.uv_x, vertex.uv_y);
    output.normal = mul(push_constant.model_matrix, mul(skin_matrix, float4(vertex.normal, 0.0))).xyz;
    output.world_position = world_position.xyz;
    return output;
}

static const float2 poisson[12] = { float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621), float2(0.962, -0.195),
    float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893), float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933),
    float2(-0.792, -0.598) };
static const float shadow_map_size = 2048.0;

float shadowFactor(float3 world_position, float3 normal) {
    float view_distance = distance(scene_data.camera_position.xyz, world_position);
    int cascade;
    if (view_distance < cascade_data.splits.x)
        cascade = 0;
    else if (view_distance < cascade_data.splits.y)
        cascade = 1;
    else if (view_distance < cascade_data.splits.z)
        cascade = 2;
    else
        return 1.0;

    float texel_world = 2.0 / (cascade_data.light_view_proj[cascade][0][0] * shadow_map_size);
    float3 sample_position = world_position + normalize(normal) * texel_world * 1.5;

    float4 light_position = mul(cascade_data.light_view_proj[cascade], float4(sample_position, 1.0));
    float3 ndc = light_position.xyz; // orthographic: w == 1
    float2 uv = ndc.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0) return 1.0;

    float texel = 1.0 / shadow_map_size;
    float pcf_radius = 2.0 * texel;
    float depth_reference = ndc.z - 0.0005;
    float sum = 0.0;
    for (int i = 0; i < 12; i++) {
        float2 tap = clamp(uv + poisson[i] * pcf_radius, float2(texel), float2(1.0 - texel));
        tap.x = (tap.x + float(cascade)) / 3.0;
        sum += shadow_map.SampleCmp(tap, depth_reference);
    }
    return sum / 12.0;
}

[shader("fragment")]
float4 mesh_frag(VertexOutput input) : SV_Target {
    const float ambient = 0.4;

    const float3 norm_to_sun = normalize(scene_data.to_sun);
    const float t = dot(-input.world_position, norm_to_sun);
    const float d = sqrt(dot(input.world_position, input.world_position) - t * t);
    const float sun_visibility = (t > 0) ? smoothstep(scene_data.planet_radius - 8, scene_data.planet_radius - 5, d) : 1;
    float direct = max(dot(normalize(input.normal), norm_to_sun), 0.0) * sun_visibility;
    float shading = ambient + (direct > 0.0 ? (1.0 - ambient) * direct * shadowFactor(input.world_position, input.normal) : 0.0);

    float dist = distance(scene_data.camera_position.xyz, input.world_position);
    float fog = (1 - exp(-dist * 0.005));

    float4 texel = textures[push_constant.texture_index].Sample(input.uv);
    float3 lit = (texel.xyz * input.color.xyz * shading) * scene_data.light_color.xyz;
    lit = lerp(lit, fog_color, fog);
    return float4(lit, texel.a * input.color.a);
}
