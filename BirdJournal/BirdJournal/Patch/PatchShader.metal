#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A patch lit by the app (issue #134, guide page 13). The layer is the patch's colour on transparency, drawn inside the
// `face` rectangle with room around it for the shadow. `layers` is the pack's half-size layers: height in red (thread
// relief plus the raised cord), the cord's mask in green. Diffuse shading and a soft sheen come from the height's normal
// under one light; the sheen is strongest on the cord. A two-part shadow falls opposite the light. With `pattern` at 1 the
// patch hasn't been sewn: the cord stays, and bare twill takes the rest, with the patch's own stitch lines (where the
// painting's colour changes) drawn on it in transfer pen.

// The shadow (guide page 16), in points for a patch at full size. Its strength comes from `softStrength`.
constant float softOffset = 9.0;
constant float softBlur = 10.0;
constant float contactOffset = 1.0;
constant float contactBlur = 2.0;
constant float contactStrengthLimit = 0.5;

// How much of the patch covers `point` when blurred over `radius`: thirteen taps, two rings and the centre.
static float blurredCoverage(SwiftUI::Layer layer, float2 point, float radius) {
    constexpr float2 ring[4] = {float2(1, 0), float2(0, 1), float2(-1, 0), float2(0, -1)};
    constexpr float2 outer[8] = {float2(0.92, 0.38), float2(0.38, 0.92), float2(-0.38, 0.92), float2(-0.92, 0.38),
                                 float2(-0.92, -0.38), float2(-0.38, -0.92), float2(0.38, -0.92), float2(0.92, -0.38)};
    float sum = layer.sample(point).a * 2.0;
    for (int i = 0; i < 4; i++) sum += layer.sample(point + ring[i] * radius * 0.5).a * 1.5;
    for (int i = 0; i < 8; i++) sum += layer.sample(point + outer[i] * radius).a;
    return sum / 16.0;
}

// How strongly the painting's colour changes across `point`, as the change itself (0...1) over a blur of `radius`: the
// stitch lines a pattern traces, wide enough that the thread's grain doesn't speckle them.
static float paintedEdge(SwiftUI::Layer layer, float2 point, float radius) {
    constexpr float2 ring[8] = {float2(1, 0), float2(0.71, 0.71), float2(0, 1), float2(-0.71, 0.71),
                                float2(-1, 0), float2(-0.71, -0.71), float2(0, -1), float2(0.71, -0.71)};
    float2 gradient = float2(0);
    for (int i = 0; i < 8; i++) {
        half4 tap = layer.sample(point + ring[i] * radius);
        float lightness = dot(float3(tap.rgb), float3(0.2126, 0.7152, 0.0722)) / max(float(tap.a), 0.001);
        gradient += ring[i] * lightness;
    }
    return length(gradient) / 2.7;
}

[[ stitchable ]] half4 patchLit(float2 position, SwiftUI::Layer layer,
                                float2 light, float4 face, float2 texel, float scale, float softStrength, float pattern,
                                half4 ground, half4 pen, texture2d<half> layers) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    half4 colour = layer.sample(position);

    // Both parts scale with the patch, so a thumbnail's shadow doesn't reach its neighbour.
    half4 shadow = half4(0);
    if (colour.a < 0.995) {
        float2 away = -light * softOffset * scale / max(length(light), 0.001);
        float soft = blurredCoverage(layer, position - away, softBlur * scale) * softStrength;
        float contact = blurredCoverage(layer, position + light * contactOffset * scale, contactBlur * scale) * min(softStrength * 1.32, contactStrengthLimit);
        float alpha = 1.0 - (1.0 - soft) * (1.0 - contact);
        shadow = half4(0, 0, 0, half(alpha));
    }
    if (colour.a <= 0.002) return shadow;

    float2 uv = (position - face.xy) / face.zw;
    half4 here = layers.sample(linear, uv);
    float cord = here.g;

    // The height's slope, by the Sobel kernel so the thread's grain doesn't alias.
    float tl = layers.sample(linear, uv + texel * float2(-1, -1)).r;
    float tc = layers.sample(linear, uv + texel * float2(0, -1)).r;
    float tr = layers.sample(linear, uv + texel * float2(1, -1)).r;
    float cl = layers.sample(linear, uv + texel * float2(-1, 0)).r;
    float cr = layers.sample(linear, uv + texel * float2(1, 0)).r;
    float bl = layers.sample(linear, uv + texel * float2(-1, 1)).r;
    float bc = layers.sample(linear, uv + texel * float2(0, 1)).r;
    float br = layers.sample(linear, uv + texel * float2(1, 1)).r;
    float dx = (tr + 2.0 * cr + br) - (tl + 2.0 * cl + bl);
    float dy = (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr);

    half3 base = colour.rgb / max(colour.a, half(0.001));
    if (pattern > 0.5) {
        // Bare twill: its diagonal rib, the painting's cord, and the stitch lines in transfer pen inside the cord.
        float rib = 0.97 + 0.03 * sin((position.x + position.y) * 2.4 / max(scale, 0.4));
        half3 twill = ground.rgb * half(rib);
        float inside = smoothstep(0.05, 0.0, cord);
        float edge = paintedEdge(layer, position, 3.4 * scale);
        float line = smoothstep(0.10, 0.22, edge) * inside;
        twill = mix(twill, pen.rgb, half(line * 0.62));
        base = mix(twill, base, half(smoothstep(0.35, 0.65, cord)));
        dx *= cord;
        dy *= cord;
    }

    // Diffuse: 1 for a flat patch with the light at rest, darker turned away, a little lighter turned toward.
    float3 normal = normalize(float3(-dx * 1.6, -dy * 1.6, 1.0));
    float3 toLight = normalize(float3(light.x, light.y, 1.0));
    float flat_ = toLight.z;
    float diffuse = 0.34 + 0.70 * dot(normal, toLight) / flat_;

    // The sheen: a broad highlight on the thread, tighter and stronger on the raised cord.
    float3 halfway = normalize(toLight + float3(0, 0, 1));
    float facing = max(dot(normal, halfway), 0.0);
    float threadSheen = pow(facing, 22.0) * 0.10 * (1.0 - cord);
    float cordSheen = pow(facing, 9.0) * 0.13 * cord;

    half3 lit = base * half(clamp(diffuse, 0.5, 1.28)) + half3(half(threadSheen + cordSheen)) * half3(1.0, 0.98, 0.94);
    half3 premultiplied = min(lit, half3(1.0)) * colour.a;
    return half4(premultiplied + shadow.rgb * (1.0 - colour.a), colour.a + shadow.a * (1.0 - colour.a));
}
