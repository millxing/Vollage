// Adapted from the FrameShift Metal kernels.
nonisolated enum ShaderSource {
    static let code = #"""
#include <metal_stdlib>
using namespace metal;

struct Info {
    uint width;
    uint height;
    uint head;      // ring slot of the current frame
    uint depth;     // ring size
    uint filled;    // frames in the ring (>= 1)
    float time;     // clip time in seconds
    uint hasPrev;   // prev holds a real accumulator
};

constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler mirror(coord::normalized, address::mirrored_repeat, filter::linear);

#define EFFECT_ARGS \
    texture2d<float, access::sample> src [[texture(0)]], \
    texture2d<float, access::write> dst [[texture(1)]], \
    texture2d_array<float, access::sample> hist [[texture(2)]], \
    texture2d<float, access::sample> prev [[texture(3)]], \
    texture2d<float, access::write> accOut [[texture(4)]], \
    constant float *p [[buffer(0)]], \
    constant Info &info [[buffer(1)]], \
    uint2 gid [[thread_position_in_grid]]

#define GUARD if (gid.x >= info.width || gid.y >= info.height) return; \
    float2 size = float2(info.width, info.height); \
    float2 uv = (float2(gid) + 0.5) / size;

// The frame k frames ago from the input history, clamped to what is filled.
static float4 past(texture2d_array<float, access::sample> hist, constant Info &info, float2 uv, uint k) {
    uint kk = min(k, info.filled - 1);
    uint slot = (info.head + info.depth - kk) % info.depth;
    return hist.sample(lin, uv, slot);
}

// A fractional number of frames ago, blended between the two nearest frames.
static float4 pastSmooth(texture2d_array<float, access::sample> hist, constant Info &info, float2 uv, float k) {
    k = clamp(k, 0.0, float(info.filled - 1));
    uint a = uint(floor(k));
    float t = k - float(a);
    return mix(past(hist, info, uv, a), past(hist, info, uv, a + 1), t);
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 q = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 r = mix(float4(q.xyw, c.r), float4(c.r, q.yzx), step(q.x, c.r));
    float d = r.x - min(r.w, r.y);
    float e = 1.0e-10;
    return float3(abs(r.z + (r.w - r.y) / (6.0 * d + e)), d / (r.x + e), r.x);
}

static float3 hsv2rgb(float3 c) {
    float3 q = clamp(abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return c.z * mix(float3(1.0), q, c.y);
}

static float hash(float2 v) { return fract(sin(dot(v, float2(127.1, 311.7))) * 43758.5453123); }

// Smooth value noise in [0, 1].
static float noise(float2 v) {
    float2 i = floor(v);
    float2 f = fract(v);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 v) {
    float sum = 0.0, amp = 0.5;
    for (int o = 0; o < 4; o++) { sum += amp * noise(v); v *= 2.03; amp *= 0.5; }
    return sum / 0.9375;
}

kernel void k_push(texture2d<float, access::read> src [[texture(0)]],
                   texture2d_array<float, access::write> hist [[texture(1)]],
                   constant uint &slot [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    hist.write(src.read(gid), gid, slot);
}

kernel void k_mix(texture2d<float, access::read> input [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  texture2d<float, access::read> fx [[texture(2)]],
                  constant float &amount [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(mix(input.read(gid), fx.read(gid), amount), gid);
}

kernel void k_output(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(saturate(src.read(gid).rgb), 1.0), gid);
}

kernel void k_slitScan(EFFECT_ARGS) {
    GUARD
    int dir = int(p[0]);
    float span = p[1];
    float pos = dir == 0 ? uv.y : dir == 1 ? 1.0 - uv.y : dir == 2 ? uv.x : 1.0 - uv.x;
    dst.write(pastSmooth(hist, info, uv, pos * (span - 1.0)), gid);
}

kernel void k_videoFeedback(EFFECT_ARGS) {
    GUARD
    float4 cur = src.sample(lin, uv);
    float3 out = cur.rgb;
    if (info.hasPrev != 0) {
        float a = p[2] * M_PI_F / 180.0;
        float aspect = size.x / size.y;
        float2 c = (uv - 0.5) * float2(aspect, 1.0);
        c = float2(c.x * cos(a) + c.y * sin(a), -c.x * sin(a) + c.y * cos(a)) / p[1];
        float2 s = c / float2(aspect, 1.0) + 0.5;
        float3 fb = prev.sample(mirror, s).rgb;
        float3 hsv = rgb2hsv(fb);
        hsv.x = fract(hsv.x + p[3]);
        fb = hsv2rgb(hsv) * p[0];
        int blend = int(p[4]);
        if (blend == 0) out = mix(cur.rgb, fb, p[0]);
        else if (blend == 1) out = cur.rgb * (1.0 - p[0] * 0.5) + fb;
        else if (blend == 2) out = max(cur.rgb, fb);
        else out = abs(cur.rgb - fb);
    }
    out = clamp(out, 0.0, 1.0);
    dst.write(float4(out, 1.0), gid);
    accOut.write(float4(out, 1.0), gid);
}

kernel void k_displacementMap(EFFECT_ARGS) {
    GUARD
    int source = int(p[0]);
    float t = info.time * p[3];
    float2 q = uv * p[2] * float2(size.x / size.y, 1.0);
    float2 d;
    if (source == 0) d = float2(fbm(q + float2(t, 0.0)), fbm(q + float2(5.2, 1.3 - t))) * 2.0 - 1.0;
    else if (source == 1) d = float2(sin(q.y * 6.2832 + t * 6.2832), cos(q.x * 6.2832 + t * 4.0));
    else if (source == 2) {
        float2 c = (uv - 0.5) * float2(size.x / size.y, 1.0);
        float w = sin(length(c) * p[2] * 12.0 - t * 6.2832);
        d = normalize(c + 1e-5) * w;
    } else {
        float l = luma(src.sample(lin, uv).rgb) * 2.0 - 1.0;
        d = float2(l, l);
    }
    int axis = int(p[4]);
    if (axis == 1) d.y = 0.0;
    if (axis == 2) d.x = 0.0;
    float2 s = uv + d * p[1] * float2(1.0, size.x / size.y);
    dst.write(float4(src.sample(mirror, s).rgb, 1.0), gid);
}
"""#
}
