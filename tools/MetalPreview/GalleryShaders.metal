// GalleryShaders.metal — preview-only.
//
// **Not compiled into any app target.** `tools/MetalPreview/build.sh` compiles
// it alongside the app's real `Design/Shaders/CardEffects.metal` into one
// `default.metallib` for the harness.
//
// This holds the full-screen backdrop composite that was prototyped for
// `PlayerView.CinematicBackground` and then **rejected**. It lives here rather
// than in the app because it is evidence, not product: it is the thing the
// measurements below were taken against, and keeping it runnable is the
// difference between "we tried that" and "we tried that, here is what it did,
// run it yourself".
//
// ── What it does ────────────────────────────────────────────────────────
//
// Collapses five SwiftUI layers — a 3x3 `MeshGradient` at `.plusLighter`, an
// `AngularGradient` at `.plusLighter`, a `RadialGradient` at `.screen`, a
// black scrim, and a vignette — into one pass, and replaces the scrim with a
// **per-pixel luminance clamp** (`clampLuminance`) enforcing
// `SCAmbient.backgroundLuminanceCeiling` (0.14).
//
// The clamp is the interesting part. `SCAmbient.scrimAlpha` carries a
// documented apology — `additiveHeadroom` is "a measured multiplier, not a
// derived one … an allowance for `.plusLighter`/`.screen` layers stacked above
// the artwork, which lighten by an amount no closed form here can know." In a
// shader the composite *is* a closed form, so the ceiling can be enforced
// exactly, per pixel, instead of approximated once per artwork from the
// artwork's **mean** — which is why the shipping version misses local bright
// patches.
//
// ── Why it was rejected ─────────────────────────────────────────────────
//
// Measured on an Apple TV 4K (3rd gen), tvOS 27.0, same artwork and palette,
// clamp disabled so only the layer arithmetic is being compared:
//
//     SwiftUI five-layer stack   background luminance p50 = 0.1159
//     this shader                background luminance p50 = 0.0272
//
// ~4.3x darker. It is not a drop-in reconstruction — it re-grades the screen —
// and re-deriving the whole look means changing the brand colours, which was
// ruled out. The mechanism is most likely a colour-space/transfer-function
// difference on shader I/O versus the encoded-space compositing SwiftUI does
// (`SCAmbient.composite` documents that it composites in encoded space); that
// part is **inferred**, not established.
//
// With the clamp on it did hold the contract exactly — % of background pixels
// over the 0.14 ceiling went 27.2% -> 0.0%, every text ratio equal or better.
// So the *contract* idea is sound even though this implementation is not
// adoptable. The 27.2% figure is a real, current bug in `scrimAlpha` and is
// fixable in `SCAmbient` with no shader at all.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace gallery {

inline float wcagLinear(float v) {
    v = clamp(v, 0.0f, 1.0f);
    return v <= 0.03928f ? v / 12.92f : powr((v + 0.055f) / 1.055f, 2.4f);
}

/// Same coefficients as `SCAmbient.relativeLuminance` — the same contract
/// evaluated somewhere else, not a second opinion about it.
inline float relativeLuminance(float3 c) {
    return 0.2126f * wcagLinear(c.r) + 0.7152f * wcagLinear(c.g) + 0.0722f * wcagLinear(c.b);
}

/// Identity below the knee, then a soft roll-off asymptotic to `ceiling`.
///
/// The knee exists so this is C1-continuous where it starts biting: a hard
/// `if (L > ceiling)` is continuous in value but not in slope, and a slope
/// discontinuity across a smooth blurred gradient renders as a visible contour.
/// It also preserves the promise `scrimAlpha` makes by returning 0 — anything
/// already dark enough passes through untouched.
inline float3 clampLuminance(float3 c, float ceiling) {
    const float L = relativeLuminance(c);
    const float knee = ceiling * 0.60f;
    if (L <= knee) { return c; }
    const float span = ceiling - knee;
    const float target = knee + span * (1.0f - exp(-(L - knee) / span));
    // Channels scaled equally => HSB brightness alone moves, hue and
    // saturation are preserved. Same reasoning as `SCAmbient.background`.
    return c * powr(target / max(L, 1e-5f), 1.0f / 2.4f);
}

inline float3 plusLighter(float3 dst, float3 src, float a) {
    return min(dst + src * a, 1.0f);
}

inline float3 screenBlend(float3 dst, float3 src, float a) {
    return mix(dst, dst + src - dst * src, a);
}

inline float3 saturate3(float3 c, float s) {
    const float grey = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
    return max(mix(float3(grey), c, s), 0.0f);
}

/// 3x3 mesh as a smoothstepped bilinear patch. Not bit-exact against SwiftUI's
/// Bezier-patch `MeshGradient`, and it does not need to be: it lands at 0.40
/// opacity in `plusLighter` over a radius-160 blur.
inline float3 mesh3x3(float2 uv, float drift, thread const float3 *c) {
    float2 p = clamp(uv + float2(drift, -drift) * (uv.y - 0.5f) * 2.0f, 0.0f, 1.0f);
    const float2 g = p * 2.0f;
    const int2 i0 = int2(min(floor(g), 1.0f));
    const float2 f = smoothstep(0.0f, 1.0f, g - float2(i0));
    const int base = i0.y * 3 + i0.x;
    return mix(mix(c[base], c[base + 1], f.x), mix(c[base + 3], c[base + 4], f.x), f.y);
}

inline float angularRamp(float2 uv, float2 centre, float angle) {
    const float2 d = uv - centre;
    float t = (atan2(d.y, d.x) - angle) * (1.0f / (2.0f * M_PI_F));
    t = fract(t + 1.0f);
    return 1.0f - abs(t - 0.5f) * 2.0f;
}

inline float radialRamp(float2 p, float2 centre, float r0, float r1) {
    return 1.0f - saturate((distance(p, centre) - r0) / max(r1 - r0, 1e-4f));
}

inline float vignetteAlpha(float y, float top, float bottom) {
    if (y < (1.0f / 3.0f)) { return mix(top, 0.0f, y * 3.0f); }
    if (y > (2.0f / 3.0f)) { return mix(0.0f, bottom, (y - (2.0f / 3.0f)) * 3.0f); }
    return 0.0f;
}

} // namespace gallery

/// The rejected `CinematicBackground` composite.
///
/// `debugMode`: 0 normal, 1 uv as red/green, 2 composite with the clamp
/// skipped, 3 relative luminance as greyscale.
///
/// Mode 1 is not decoration — it is how the single worst bug in this shader was
/// found. `position` is **not** in the view's coordinate space: a `.blur()` or
/// `.scaleEffect()` inside the effected content enlarges the space the shader
/// is evaluated over. Measured in the real app, a 1920x1080 backdrop holding a
/// 2.1x-scaled, radius-160-blurred image was evaluated over ~2110x1895 with the
/// visible area starting at (99, 297), so normalising by `proxy.size` put the
/// whole screen inside `uv.y` 0.16...0.73 — and the vignette, a function of
/// `uv.y`, darkened the *entire* frame by ~18% instead of just its edges.
/// `Shader.Argument.boundingRect` is delivered in the same space as `position`
/// and cannot drift.
[[ stitchable ]]
half4 backdropComposite(
    float2 position,
    half4 color,
    float4 bounds,
    half4 primary,
    half4 secondary,
    half4 average,
    float meshPhase,
    float driftAngle,       // radians
    float energy,           // 0...1, or negative for "not modulated"
    float luminanceCeiling,
    float saturationAmount,
    float debugMode
) {
    using namespace gallery;

    const float alpha = max(float(color.a), 1e-4f);
    float3 c = float3(color.rgb) / alpha;
    c = saturate3(c, saturationAmount);

    const float2 local = position - bounds.xy;
    const float2 extent = max(bounds.zw, float2(1.0f));
    const float2 uv = clamp(local / extent, 0.0f, 1.0f);

    if (debugMode > 0.5f && debugMode < 1.5f) {
        return half4(half(uv.x), half(uv.y), 0.0h, 1.0h);
    }

    const float3 p = float3(primary.rgb);
    const float3 s = float3(secondary.rgb);
    const float3 a = float3(average.rgb);
    float3 stops[9] = {
        p,         p * 0.85f, s,
        p * 0.75f, a,         s * 0.85f,
        s,         s * 0.85f, p
    };
    c = plusLighter(c, mesh3x3(uv, meshPhase * 0.10f, stops), 0.40f);

    const float conicOpacity = energy >= 0.0f ? (0.55f + 0.18f * energy) : 0.55f;
    c = plusLighter(c, s, angularRamp(uv, float2(0.0f, 1.0f), driftAngle) * 0.35f * conicOpacity);

    const float radialOpacity = energy >= 0.0f ? (0.74f + 0.26f * energy) : 1.0f;
    c = screenBlend(c, p, radialRamp(local, float2(0.0f), 80.0f, 1500.0f) * 0.40f * radialOpacity);

    if (debugMode > 1.5f) {
        if (debugMode < 2.5f) { return half4(half3(c * alpha), color.a); }
        return half4(half3(half(relativeLuminance(c))), 1.0h);
    }

    // Where the black scrim sat: above every lightening layer, below only the
    // vignette. That position was load-bearing for the layer stack and is
    // load-bearing here for the same reason — a clamp applied *under* the
    // additive layers bounds none of them.
    c = clampLuminance(c, luminanceCeiling);

    // After the clamp deliberately: it only darkens, so it cannot lift a pixel
    // back over the ceiling.
    c = mix(c, float3(0.0f), vignetteAlpha(uv.y, 0.35f, 0.85f));

    return half4(half3(c * alpha), color.a);
}
