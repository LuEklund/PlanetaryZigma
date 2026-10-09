[[vk::binding(0, 0)]] Sampler2D textures[256];

struct Vertex {
    float2 position;
    float2 uv;
    uint color;
};

struct PushConstant {
    Vertex *vertex_buffer;
    float2 screen_size;
    uint texture_index;
};
[[vk::push_constant]] PushConstant push_constant;

struct VertexOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
    Vertex vertex = push_constant.vertex_buffer[vertex_index];
    VertexOutput output;
    output.position = float4(vertex.position / push_constant.screen_size * 2.0 - 1.0, 0.0, 1.0);
    output.color = unpackUnorm4x8ToFloat(vertex.color);
    output.uv = vertex.uv;
    return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
    return textures[push_constant.texture_index].Sample(input.uv) * input.color;
}
