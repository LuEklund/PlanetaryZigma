#version 450
#extension GL_EXT_buffer_reference : require

struct Vertex {
  vec3 position;
  float uv_x;
  vec3 normal;
  float uv_y;
  vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
  Vertex vertices[];
};

layout(push_constant, std430) uniform pc {
  mat4 model_matrix;
  VertexBuffer vertex_buffer;
} push_constant;

void main() {
  Vertex v = push_constant.vertex_buffer.vertices[gl_VertexIndex];
  gl_Position = push_constant.model_matrix * vec4(v.position, 1.0);
}
