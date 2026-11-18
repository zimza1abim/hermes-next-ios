#include <metal_stdlib>
using namespace metal;

// The Android aura (AuraAgsl.kt), which is the mock's GLSL moved to AGSL.
// Drawn by MTKView rather than a SwiftUI stitchable shader: the simplex stack is too
// large for SwiftUI's stitcher, and a display-link draw does not invalidate the SwiftUI body.

struct AuraUniforms {
    float2 uRes;
    float2 uOrigin;
    float uTime;
    float uFlow;
    float uH;
    float uSwell;
    float uRipple;
    float uSweep;
    float uFlash;
    float uDir;
    float uBright;
    float uSat;
    float uMini;
    float uDetail;
    float4 cA;
    float4 cB;
    float4 cC;
    float4 cD;
};

struct AuraVertexOut {
    float4 position [[position]];
};

vertex AuraVertexOut aura_vertex(uint vid [[vertex_id]]) {
    float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    AuraVertexOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    return out;
}

static float3 mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289_4(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 permute(float4 x) { return mod289_4(((x * 34.0) + 1.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289_3(i);
    float4 p = permute(permute(permute(
                  i.z + float4(0.0, i1.z, i2.z, 1.0))
                + i.y + float4(0.0, i1.y, i2.y, 1.0))
                + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

static float fbm(float3 p, float detail) {
    float f = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        if (float(i) >= detail) { break; }
        f += a * snoise(p);
        p = p * 2.02 + float3(1.7, 9.2, 3.1);
        a *= 0.5;
    }
    return f;
}

static float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

fragment float4 aura_fragment(AuraVertexOut in [[stage_in]], constant AuraUniforms &u [[buffer(0)]]) {
    float2 fc = in.position.xy + u.uOrigin;
    float2 uv = float2(fc.x / u.uRes.x, 1.0 - fc.y / u.uRes.y);
    float ar = u.uRes.x / u.uRes.y;
    float2 p = float2(uv.x * ar, uv.y);
    float ex = uv.x;
    if (u.uMini > 0.5) {
        p = float2(uv.x * ar * 0.12, uv.y * 0.5);
        ex = uv.x * 1.2;
    }
    float3 A = float3(u.cA.rgb);
    float3 B = float3(u.cB.rgb);
    float3 Cc = float3(u.cC.rgb);
    float3 Dd = float3(u.cD.rgb);

    float3 bg = mix(float3(0.027, 0.027, 0.043), float3(0.043, 0.043, 0.063), uv.y);
    if (u.uMini > 0.5) { bg = float3(0.043, 0.039, 0.055); }
    float vig = 1.0;
    if (u.uMini < 0.5) {
        float2 vv = (uv - float2(0.5, 0.45)) * float2(1.0, 1.2);
        vig = mix(0.82, 1.0, 1.0 - smoothstep(0.35, 1.25, length(vv)));
    }
    float grain = (hash21(fc + fract(u.uTime) * 91.0) - 0.5) * 0.022;

    float T = u.uFlow;
    float edge = u.uH + 0.045 * snoise(float3(ex * 1.4, 0.0, T * 0.22))
                    + 0.015 * snoise(float3(ex * 3.2, 3.0, T * 0.35));
    float cx = (uv.x - 0.5 + 0.12 * sin(T * 0.3)) * 2.0;
    edge += u.uSwell * 0.10 * exp(-cx * cx);
    edge += u.uRipple * 0.010 * sin(uv.x * 44.0 + u.uTime * 7.0)
            * (0.5 + 0.5 * snoise(float3(uv.x * 2.5, 7.0, u.uTime * 0.9)));
    float d = uv.y - edge;

    if (d > 0.6) {
        return float4(bg * vig + grain, 1.0);
    }

    float2 sp = p * float2(1.0 - u.uSweep * 0.5, 1.0) * 0.85;
    float2 fl = float2(u.uDir * T * 0.30, -T * 0.05);
    float2 q = float2(fbm(float3(sp * 0.9 + fl, T * 0.10), u.uDetail),
                      fbm(float3(sp * 0.9 + float2(5.2, 1.3) + fl, T * 0.10), u.uDetail));
    float f = fbm(float3(sp * 0.8 + 1.3 * q + fl * 0.5, T * 0.08), u.uDetail);
    f = clamp(0.5 + 0.62 * f, 0.0, 1.0);
    float g = clamp(0.5 + 0.6 * fbm(float3(sp * 0.6 + float2(3.1, 7.7) - fl * 0.4, T * 0.06 + 4.0), u.uDetail), 0.0, 1.0);

    float depth = smoothstep(0.0, 0.62, -d);
    float body = 1.0 - smoothstep(-0.30, 0.04, d);
    float haze = exp(-max(d, 0.0) * 5.5) * 0.32 * (1.0 - body);
    float crest = exp(-abs(d + 0.02) * 16.0) * (0.35 + 0.65 * f) * 0.75;

    float3 deep = mix(A * 0.35, Dd * 0.35, g) + float3(0.015, 0.0, 0.03);
    float3 inner = mix(A, Dd, smoothstep(0.35, 0.75, g));
    float pools = smoothstep(0.40, 0.95, f * 0.85 + 0.25 * g);
    inner = mix(inner, mix(B, Cc, pools), pools * 0.85);
    float3 c = mix(inner * (0.45 + 0.85 * f), deep, depth * 0.8) * body
             + mix(B, Cc, f) * crest * (0.8 + 0.7 * u.uSwell)
             + mix(B, Dd, 0.4) * haze;

    float sx = fract(u.uTime * 0.18 + 0.35) * 1.8 - 0.4;
    float bx = (uv.x - sx - (uv.y - edge) * 0.5) * 4.5;
    float band = exp(-bx * bx);
    c += u.uSweep * band * (Cc * crest * 0.7 + B * body * 0.30 * (1.0 - depth * 0.6) + Cc * haze * 0.6);

    c += u.uFlash * (float3(1.0, 0.9, 0.95) * crest * 0.45 + B * exp(-max(d, 0.0) * 3.5) * 0.25 * (1.0 - body));

    c *= u.uBright;
    c = pow(max(c, float3(0.0)), float3(1.45)) * 1.75;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(lum), c, u.uSat);
    c = c / (1.0 + c * 0.35);
    float3 o = (bg + c) * vig + grain;
    return float4(o, 1.0);
}
