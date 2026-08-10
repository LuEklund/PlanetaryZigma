import scene;

[[vk::binding(0, 1)]]
Sampler2D textures[256];

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

// Second pass
struct OutlineOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
OutlineOutput highlight_outline_vert(uint vertex_index: SV_VertexID) {
    float2 corner = float2((vertex_index << 1) & 2, vertex_index & 2);
    OutlineOutput output;
    output.uv = corner;
    output.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

[shader("fragment")]
float4 highlight_outline_frag(OutlineOutput input) : SV_Target {
    Sampler2D mask = textures[push_constant.texture_index];

    uint width, height;
    mask.GetDimensions(width, height);
    float2 texel = 6.0 / float2(width, height);

    float center = mask.Sample(input.uv).r;
    float left = mask.Sample(input.uv - float2(texel.x, 0)).r;
    float right = mask.Sample(input.uv + float2(texel.x, 0)).r;
    float up = mask.Sample(input.uv - float2(0, texel.y)).r;
    float down = mask.Sample(input.uv + float2(0, texel.y)).r;

    if (center < 0.5 || min(min(left, right), min(up, down)) > 0.5) discard;
    return float4(1.0, 0.82, 0.35, 1.0);
}

