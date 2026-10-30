#version 320 es

#include <flutter/runtime_effect.glsl>

// Engine-owned input size and first sampler. All positions below are physical
// coordinates in the root backdrop, never in an Opacity/ImageFiltered buffer.
uniform vec2 u_size;
uniform vec2 u_mask_origin;
uniform vec2 u_mask_inverse_x;
uniform vec2 u_mask_inverse_y;
uniform vec2 u_sample_point;
uniform float u_opacity;
// Logical motion sigma divided by the mask's logical dimensions. Blur only
// cached alpha, never the backdrop or an additional full-size filter texture.
uniform vec2 u_mask_blur_uv;
uniform sampler2D u_backdrop;
uniform sampler2D u_glyph_mask;

out vec4 frag_color;

float mask_alpha(vec2 uv) {
  // Image samplers clamp by default; implement transparent/decal edges so
  // blurring a glyph at the texture edge cannot smear it over the surface.
  if (any(lessThan(uv, vec2(0.0))) ||
      any(greaterThan(uv, vec2(1.0)))) return 0.0;
  return texture(u_glyph_mask, uv).a;
}

float alpha_row(vec2 uv) {
  vec2 step_x = vec2(u_mask_blur_uv.x, 0.0);
  return mask_alpha(uv - 2.0 * step_x) * 0.05448868 +
      mask_alpha(uv - step_x) * 0.24420134 +
      mask_alpha(uv) * 0.40261995 +
      mask_alpha(uv + step_x) * 0.24420134 +
      mask_alpha(uv + 2.0 * step_x) * 0.05448868;
}

float softened_alpha(vec2 uv) {
  if (u_mask_blur_uv.x <= 0.0) return mask_alpha(uv);
  // Fixed 5x5 Gaussian quadrature at -2s, -s, 0, s, 2s. The kernel is
  // normalized and samples bilinearly; work stays within the small glyph
  // footprint and requires no native Gaussian intermediate/render pass.
  // Spell out the fixed taps: some mobile/ANGLE compilers keep nested loops
  // dynamic and warn about implicit texture derivatives within those loops.
  vec2 step_y = vec2(0.0, u_mask_blur_uv.y);
  return alpha_row(uv - 2.0 * step_y) * 0.05448868 +
      alpha_row(uv - step_y) * 0.24420134 +
      alpha_row(uv) * 0.40261995 +
      alpha_row(uv + step_y) * 0.24420134 +
      alpha_row(uv + 2.0 * step_y) * 0.05448868;
}

vec3 linearize_srgb(vec3 color) {
  vec3 low = color / 12.92;
  vec3 high = pow((color + vec3(0.055)) / 1.055, vec3(2.4));
  return mix(low, high, step(vec3(0.04045), color));
}

float backdrop_luminance(vec2 pixel) {
  vec2 uv = clamp(pixel / u_size, vec2(0.0), vec2(1.0));
  // The runtime-effect backdrop snapshot uses the same top-left coordinates
  // as FlutterFragCoord, including on this Impeller GLES path. A second Y
  // flip samples the opposite end of the document (often a dark page gutter).
  vec4 backdrop = texture(u_backdrop, uv);
  vec3 color = backdrop.a > 0.0001
      ? clamp(backdrop.rgb / backdrop.a, vec3(0.0), vec3(1.0))
      : vec3(0.0);
  return dot(linearize_srgb(color), vec3(0.2126, 0.7152, 0.0722));
}

void main() {
  vec2 delta = FlutterFragCoord().xy - u_mask_origin;
  vec2 mask_uv = vec2(
    dot(delta, u_mask_inverse_x),
    dot(delta, u_mask_inverse_y)
  );
  // The filter's input also covers the common sample patch. Never extend
  // clamp-to-edge glyph pixels over that extra area (or recolor the surface).
  vec2 halo = 2.0 * u_mask_blur_uv;
  if (u_opacity <= 0.0 || any(lessThan(mask_uv, -halo)) ||
      any(greaterThan(mask_uv, vec2(1.0) + halo))) {
    frag_color = vec4(0.0);
    return;
  }
  float alpha = softened_alpha(mask_uv) * u_opacity;
  if (alpha <= 0.0) {
    // Text rectangles are mostly empty. Avoid five texture reads and sRGB
    // conversions there, rather than shading every transparent fragment.
    frag_color = vec4(0.0);
    return;
  }
  // Same location for every glyph in a control, independent of glyph bounds,
  // fades, press scale and motion blur. Each control supplies its own location.
  float luminance = (
    backdrop_luminance(u_sample_point) +
    backdrop_luminance(u_sample_point + vec2(-2.0, 0.0)) +
    backdrop_luminance(u_sample_point + vec2(2.0, 0.0)) +
    backdrop_luminance(u_sample_point + vec2(0.0, -2.0)) +
    backdrop_luminance(u_sample_point + vec2(0.0, 2.0))
  ) / 5.0;
  float dark_foreground = smoothstep(0.164, 0.194, luminance);
  vec3 foreground = vec3(1.0 - dark_foreground);
  frag_color = vec4(foreground * alpha, alpha);
}
