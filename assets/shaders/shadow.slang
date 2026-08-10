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
float4 shadow_static_vert(uint vertex_index: SV_VertexID) : SV_Position {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];
    return mul(push_constant.model_matrix, float4(vertex.position, 1.0));
}

[shader("vertex")]
float4 shadow_skinned_vert(uint vertex_index: SV_VertexID) : SV_Position {
    SkinnedVertex *skinned_buffer = (SkinnedVertex *)push_constant.vertex_buffer;
    SkinnedVertex vertex = skinned_buffer[vertex_index];

    float4x4 skin_matrix = vertex.joint_weights.x * push_constant.joint_matrices[vertex.joint_indices.x] +
                           vertex.joint_weights.y * push_constant.joint_matrices[vertex.joint_indices.y] +
                           vertex.joint_weights.z * push_constant.joint_matrices[vertex.joint_indices.z] +
                           vertex.joint_weights.w * push_constant.joint_matrices[vertex.joint_indices.w];

    return mul(push_constant.model_matrix, mul(skin_matrix, float4(vertex.position, 1.0)));
}

