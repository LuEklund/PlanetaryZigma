
#version 450

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 0) out vec4 out_frag_color;

layout(set = 0, binding = 0) uniform sampler2D atlas;
void main() {
  if (in_uv == vec2(-1, -1)) {
    out_frag_color = in_color;
    return;
  }
  // SDF atlas: distance is stored around 0.5 (the glyph edge); threshold with screen-space AA.
  float dist = texture(atlas, in_uv).r;
  float width = fwidth(dist);
  float coverage = smoothstep(0.5 - width, 0.5 + width, dist);
  out_frag_color = vec4(in_color.rgb, in_color.a * coverage);
}
