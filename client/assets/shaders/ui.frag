
#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in flat uint in_texture_index;
layout(location = 3) in flat uint in_is_sdf;
layout(location = 0) out vec4 out_frag_color;

layout(set = 0, binding = 0) uniform sampler2D textures[64];
void main() {
  vec4 texture = texture(textures[nonuniformEXT(in_texture_index)], in_uv);
  if (in_is_sdf == 1) {
    float dist = texture.r;
    float width = fwidth(dist);
    float coverage = smoothstep(0.5 - width, 0.5 + width, dist);
    out_frag_color = vec4(in_color.rgb, in_color.a * coverage);
    return;
  }
  out_frag_color = texture * in_color;
}
