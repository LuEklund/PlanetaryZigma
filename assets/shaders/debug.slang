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

struct Vertex {
    float4 position;
    float4 color;
};

struct PushConstant {
    float4x4 model_matrix;
    Vertex *vertex_buffer;
    float4x4 *joint_matrices;
    uint texture_index;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];

    VertexOutput output;
    output.position = mul(scene_data.proj_view, mul(push_constant.model_matrix, float4(vertex.position.xyz, 1.0)));
    output.color = vertex.color;
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    return input.color;
}
