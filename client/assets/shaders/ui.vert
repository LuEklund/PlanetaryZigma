// vertex.glsl
#version 450
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec2 position;
  vec2 uv;
  vec4 color;
  uint texture_index;
  uint is_sdf;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  VertexBuffer vertex_buffer;
  vec2 screen_size;
} push_constant;

layout(location = 0) out vec4 out_frag_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out flat uint out_texture_index;
layout(location = 3) out flat uint out_is_sdf;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];
  vec2 ndc = v.position / push_constant.screen_size * 2 - 1;
  gl_Position = vec4(ndc, 0.0, 1.0);
  out_frag_color = v.color;
  out_uv = v.uv;
  out_texture_index = v.texture_index;
  out_is_sdf = v.is_sdf;
}
