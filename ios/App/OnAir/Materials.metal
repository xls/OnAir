// Metal surfaces for the hardware look, used through SwiftUI's colorEffect. Everything is computed per pixel, so highlights move with the phone.
#include <metal_stdlib>
using namespace metal;

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3 - 2 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
}

// Brushed aluminium: fine streaks along x, and a soft band of light that follows the tilt.
[[ stitchable ]] half4 brushedMetal(float2 position, half4 colour, float2 size, float2 light, float tone) {
    float2 uv = position / size;
    float streak = noise(float2(position.x * 0.012, position.y * 1.9)) * 0.55 + noise(float2(position.x * 0.05, position.y * 4.3)) * 0.3 + hash(position * 0.5) * 0.15;
    float band = exp(-pow((uv.y - (0.32 + light.y * 0.45)) * 2.6, 2.0));
    float cross = 0.82 + 0.18 * cos((uv.x - 0.5 - light.x * 0.6) * 3.2);
    float value = tone * (0.62 + 0.42 * band * cross) + (streak - 0.5) * 0.085;
    float3 tint = mix(float3(0.93, 0.95, 1.0), float3(1.0, 0.98, 0.95), band);
    return half4(half3(float3(value) * tint), 1);
}

// Spun metal, as on the cap of a hi-fi knob: rings of machining and the bright cones of light they make.
[[ stitchable ]] half4 spunMetal(float2 position, half4 colour, float2 size, float rotation, float2 light, float tone) {
    float2 p = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    float radius = length(p);
    if (radius > 1) return half4(0);
    float angle = atan2(p.y, p.x);
    float lit = angle - atan2(light.y + 0.75, light.x + 0.25);
    float cone = pow(abs(cos(lit)), 14.0) * 0.72 + pow(abs(cos(lit + 1.15)), 26.0) * 0.26;
    float rings = (noise(float2(radius * 160, 3.0)) - 0.5) * 0.075 + (noise(float2(radius * 42, 9.0)) - 0.5) * 0.04;
    float scratch = (hash(float2(floor((angle + rotation) * 180), floor(radius * 40))) - 0.5) * 0.02;
    float value = tone * (0.42 + cone) + rings + scratch;
    float rim = smoothstep(0.93, 1.0, radius);
    value = mix(value, 0.1, rim * 0.8);
    return half4(half3(float3(value) * float3(0.98, 0.99, 1.02)), 1);
}

// The ridged skirt around a knob, with a highlight that stays still while the ridges turn.
[[ stitchable ]] half4 knurledMetal(float2 position, half4 colour, float2 size, float rotation, float2 light) {
    float2 p = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    float radius = length(p);
    if (radius > 1) return half4(0);
    float angle = atan2(p.y, p.x);
    float ridge = 0.5 + 0.5 * cos((angle + rotation) * 56);
    float lit = 0.5 + 0.5 * dot(normalize(p), normalize(float2(-0.35 + light.x, -0.9 + light.y)));
    float value = (0.07 + 0.5 * pow(lit, 3.0)) * (0.3 + 0.7 * ridge);
    float edge = smoothstep(1.0, 0.96, radius);
    return half4(half3(value * edge), 1);
}

// The warm paper of a backlit meter.
[[ stitchable ]] half4 meterFace(float2 position, half4 colour, float2 size, float glow) {
    float2 uv = position / size;
    float lamp = exp(-(pow((uv.x - 0.5) * 1.7, 2.0) + pow((uv.y - 1.1) * 1.25, 2.0)));
    float grain = (noise(position * 0.9) - 0.5) * 0.03;
    float value = (0.3 + 0.72 * lamp) * glow + grain;
    return half4(half3(float3(1.0, 0.8, 0.5) * value), 1);
}

// ---- television: NV12 planes to RGB, on a full-screen quad
struct VideoOut { float4 position [[position]]; float2 uv; };
struct VideoUniforms { float2 scale; float bt709; float fullRange; };

vertex VideoOut videoVertex(uint id [[vertex_id]], constant VideoUniforms& u [[buffer(0)]]) {
    const float2 corner[4] = {float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)};
    VideoOut o;
    o.position = float4(corner[id] * u.scale, 0, 1);
    o.uv = float2(corner[id].x * 0.5 + 0.5, 0.5 - corner[id].y * 0.5);
    return o;
}

fragment float4 videoFragment(VideoOut in [[stage_in]], constant VideoUniforms& u [[buffer(0)]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = luma.sample(s, in.uv).r;
    float2 c = chroma.sample(s, in.uv).rg - 0.5;
    if (u.fullRange < 0.5) { y = (y - 16.0 / 255.0) * 255.0 / 219.0; c *= 255.0 / 224.0; }
    float3 rgb = u.bt709 > 0.5 ? float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x)
                               : float3(y + 1.402 * c.y, y - 0.3441 * c.x - 0.7141 * c.y, y + 1.772 * c.x);
    return float4(saturate(rgb), 1);
}

fragment float4 videoRgbaFragment(VideoOut in [[stage_in]], texture2d<float> picture [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(picture.sample(s, in.uv).rgb, 1);
}
