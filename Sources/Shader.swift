/// Metal source for the rim light, compiled at launch with `makeLibrary(source:)`.
/// Keep `Uniforms` in sync with `GlowView.uniforms` in Overlay.swift.
///
/// Each display is drawn as four strips along its edges, so only those pixels are rendered and
/// composited. Every strip runs the same shader in whole-screen coordinates: `origin` is where the
/// strip sits on the screen, `size` is the whole screen.
let glowShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;        // whole screen, in pixels
    float2 origin;      // top-left of this strip on the screen, in pixels
    float2 stripSize;   // this strip, in pixels
    float  thickness;   // glow reach in pixels
    float  corner;      // display corner radius in pixels
    float  intensity;   // master brightness (already includes fade in/out)
    float  phase;       // slow rotation of the base gradient around the rim, wraps at 1
    float  clock;       // animation clock in seconds (frozen in No Animation)
    float  pulse;       // beat envelope, 0..1, jumps on each beat then decays
    float  level;       // smoothed loudness / breathing, 0..1
    float  travel;      // position of the travelling lights around the rim, wraps at 1
    float  edr;         // extended-range headroom multiplier (1 when rendering SDR)
    float  linearOut;   // 1 when the target is a linear extended-range buffer
    float  colorCount;
    float  streaks;     // how strong the travelling lights are, 0..1
    float  accent;      // snare/clap sparkle envelope, 0..1
    float  quality;     // 0 low, 1 normal, 2 extreme
    float4 notch;       // x, y, w, h in pixels, top-left origin; w == 0 when there is no notch
    float4 colors[6];   // sRGB
    float  bands[24];   // smoothed spectrum, 0..1, bass first
    float  drop;        // burst after a breakdown, 0..1
    float  eqAmount;    // how strongly the spectrum shapes the rim, 0..1
    float  pad0;
    float  pad1;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut glow_vertex(uint vid [[vertex_id]]) {
    // One oversized triangle that covers the whole viewport.
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float3 toLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static float3 paletteAt(constant Uniforms& u, float t) {
    int n = max(int(u.colorCount), 1);
    float f = fract(t) * float(n);
    int i0 = int(floor(f)) % n;
    int i1 = (i0 + 1) % n;
    // Short transitions: each colour holds its own stretch, so opposite colours don't spend half
    // the rim as their muddy in-between.
    return mix(u.colors[i0].rgb, u.colors[i1].rgb, smoothstep(0.25, 0.75, fract(f)));
}

/// Position around the rim as a fraction of the perimeter, clockwise from the top-left corner.
/// Each side contributes its own coordinate, weighted by how close the pixel is to that side, and the
/// result is a circular mean, so colours stay continuous around the corners.
static float rimPosition(float2 px, float2 size, float blend) {
    float W = size.x, H = size.y, P = 2.0 * (W + H);
    float4 dist = float4(px.y, W - px.x, H - px.y, px.x);                        // top, right, bottom, left
    float4 s = float4(px.x, W + px.y, W + H + (W - px.x), 2.0 * W + H + (H - px.y));
    float nearest = min(min(dist.x, dist.y), min(dist.z, dist.w));
    float4 w = exp(-(dist - nearest) / max(blend, 1.0));
    float4 ang = s / P * 2.0 * M_PI_F;
    float a = atan2(dot(w, sin(ang)), dot(w, cos(ang)));
    return fract(a / (2.0 * M_PI_F) + 1.0);
}

/// A comet of light at `head` (fraction of the perimeter) moving forwards: bright head, long tail.
static float streak(float pos, float head, float len) {
    float d = fract(pos - head + 0.5) - 0.5;   // signed distance along the rim, -0.5..0.5
    float tail = exp(-max(-d, 0.0) / len);
    float nose = exp(-max(d, 0.0) / (len * 0.22));
    return tail * nose;
}

fragment float4 glow_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 px = u.origin + in.uv * u.stripSize;
    float2 c = u.size * 0.5;

    // Distance from the lit boundary, positive towards the middle of the screen. The notch is a
    // box hanging from the top edge (extended upwards so its top corners stay square), and the
    // light wraps around it like any other edge.
    float d = -sdRoundBox(px - c, c, u.corner);
    if (u.notch.z > 0.0) {
        float2 half_ = float2(u.notch.z * 0.5, u.notch.w);
        float2 center = float2(u.notch.x + half_.x, u.notch.y);
        d = min(d, max(sdRoundBox(px - center, half_, u.notch.w * 0.32), 0.0));
    }
    if (d < 0.0) { return float4(0.0); }

    // Beats brighten the tube rather than pushing it into the screen; it only swells a touch.
    float th = max(u.thickness * (1.0 + 0.12 * u.pulse + 0.05 * u.level), 1.0);
    if (d > th * 1.35) { return float4(0.0); }   // the strips are sized to this reach

    float pos = rimPosition(px, u.size, th * 0.6);

    // Base band: the album palette spread around the rim, slowly rotating.
    float3 col = paletteAt(u, pos + u.phase);

    // Travelling lights: comets (2, 3 or 4 by quality), each carrying one of the palette's colours,
    // chasing each other around the screen.
    int q = int(u.quality + 0.5);
    int count = q + 2;
    float lights = 0.0;
    float3 lightCol = float3(0.0);
    for (int k = 0; k < count; k++) {
        float head = fract(u.travel + float(k) / float(count));
        float s = streak(pos, head, 0.11);
        lights += s;
        lightCol += paletteAt(u, float(k) / float(count) + 0.17) * s;
    }
    lightCol /= max(lights, 1e-4);
    float lw = clamp(lights, 0.0, 1.0) * u.streaks;
    float spark = u.accent * lw;          // snares and claps make the travelling lights flare
    col = mix(col, lightCol, lw * 0.85);

    // Neon colour: full brightness and strongly saturated, so even pale covers glow vividly.
    col = col / max(max(col.r, max(col.g, col.b)), 1e-3);
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = clamp(mix(float3(luma), col, 1.7), 0.0, 1.0);

    // Equalizer edges: bass at the bottom centre, rising through the mids up both sides to the
    // highs at the top centre (around the notch). Each stretch of rim glows with its own band.
    float W = u.size.x, H = u.size.y;
    float bottomCentre = (W + H + 0.5 * W) / (2.0 * (W + H));
    float e = abs(fract(pos - bottomCentre + 0.5) - 0.5) * 2.0;   // 0 bottom centre .. 1 top centre
    float fi = e * 23.0;
    int b0 = min(int(fi), 23);
    int b1 = min(b0 + 1, 23);
    float eq = mix(u.bands[b0], u.bands[b1], fract(fi));
    float eqGain = mix(1.0, 0.3 + 1.4 * eq, u.eqAmount);

    // Fluorescent flow: energy rippling along the tube, two waves drifting in opposite directions.
    float flow = 0.72 + 0.28 * (0.5 + 0.5 * sin((pos * 34.0 - u.clock * 0.9) * 2.0 * M_PI_F))
                             * (0.6 + 0.4 * sin((pos * 9.0 + u.clock * 0.31) * 2.0 * M_PI_F));

    // Neon tube profile: a solid, intensely coloured tube right at the edge, a tight glow hugging it
    // and a faint haze that's gone by ~1.3 widths. Nothing reaches into the screen.
    float tubeW = max(th * 0.055, 1.5);
    float tube = exp(-(d / tubeW) * (d / tubeW));
    float near_ = exp(-d / (th * 0.16 * (1.0 + 0.25 * eq * u.eqAmount))) * (1.0 - smoothstep(1.0, 1.35, d / th));
    float haze = exp(-d / (th * 0.42)) * (1.0 - smoothstep(0.9, 1.3, d / th));
    float bloom = q >= 1 ? exp(-d / (th * 0.7)) * (q == 2 ? 0.16 : 0.12) * (1.0 - smoothstep(0.85, 1.3, d / th)) : 0.0;

    // Low resting level so the music has all the room: kicks flash the whole tube, the bass swells
    // it, accents flare the travelling lights and a drop sets everything off at once.
    // The extras get a soft knee, so a single kick lands hard but everything at once still keeps the
    // tube distinct from its glow instead of flattening into an opaque band.
    float extra = 0.7 * lw + 1.1 * u.pulse + 0.45 * u.level + 0.6 * spark + 0.8 * u.drop;
    float drive = 0.45 + 2.0 * tanh(extra / 2.0);
    float g = ((tube * 1.1 * flow + near_ * 0.75 * (0.8 + 0.2 * flow)) * eqGain + haze * 0.32 + bloom) * u.intensity * drive;

    // Soft saturation that tops out just short of opaque: fuller as it brightens, always the colour,
    // never a flat white sheet.
    float a = 0.95 * (1.0 - exp(-g * 2.4));
    float3 rgb = col * 0.95 * (1.0 - exp(-g * 2.2));

    if (u.linearOut > 0.5) {
        rgb = toLinear(clamp(rgb, 0.0, 1.0));
        // Extra headroom goes to the tube itself, like a real neon light.
        float boost = 1.0 + (min(u.edr, 2.2) - 1.0) * clamp(tube * (0.7 + 0.3 * u.pulse) + (u.pulse * 0.3 + lw * 0.3) * near_, 0.0, 1.0);
        rgb *= boost;
    } else if (q < 2) {
        // Dither the 8-bit output so the long falloff doesn't band (Extreme renders 16-bit colour).
        float n0 = (hash(px + fract(u.clock)) - 0.5) / 255.0;
        rgb = clamp(rgb + n0, 0.0, a);
    }
    return float4(rgb, a);
}
"""
