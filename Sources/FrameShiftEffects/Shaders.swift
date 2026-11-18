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

static float hash1(float v) { return fract(sin(v * 91.3458) * 47453.5453); }
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

// out = mix(input, effect, amount * mask)
kernel void k_mix(texture2d<float, access::read> input [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  texture2d<float, access::read> fx [[texture(2)]],
                  texture2d<float, access::sample> mask [[texture(3)]],
                  constant float &amount [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float m = mask.sample(lin, uv).r * amount;
    dst.write(mix(input.read(gid), fx.read(gid), m), gid);
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
    float k = pos * (span - 1.0);
    // The first step blends from the live frame, so the leading edge is never stale.
    float4 older = pastSmooth(hist, info, uv, k);
    dst.write(k < 1.0 ? mix(src.sample(lin, uv), older, k) : older, gid);
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

// p: map, depth, scale, speed
kernel void k_timeDisplacement(EFFECT_ARGS) {
    GUARD
    int map = int(p[0]);
    float depth = p[1];
    float t = info.time * p[3];
    float m;
    if (map == 0) m = fbm(uv * p[2] * float2(size.x / size.y, 1.0) + float2(t, t * 0.7));
    else if (map == 1) m = uv.y;
    else if (map == 2) m = uv.x;
    else if (map == 3) m = saturate(length(uv - 0.5) * 1.4142);
    else m = 1.0 - luma(src.sample(lin, uv).rgb);
    dst.write(pastSmooth(hist, info, uv, m * (depth - 1.0)), gid);
}

// p: echoes, spacing, decay, blend
kernel void k_motionEcho(EFFECT_ARGS) {
    GUARD
    int echoes = int(p[0]);
    uint spacing = uint(p[1]);
    float decay = p[2];
    int blend = int(p[3]);
    float4 cur = src.sample(lin, uv);
    float3 acc = cur.rgb;
    float weight = 1.0;
    float w = 1.0;
    for (int i = 1; i < echoes; i++) {
        w *= decay;
        float3 c = past(hist, info, uv, uint(i) * spacing).rgb;
        if (blend == 0) { acc += c * w; weight += w; }
        else if (blend == 1) acc = max(acc, mix(cur.rgb, c, w));
        else acc = min(acc, mix(cur.rgb, c, w));
    }
    dst.write(float4(blend == 0 ? acc / weight : acc, 1.0), gid);
}

// p: mode, window
kernel void k_timeStacking(EFFECT_ARGS) {
    GUARD
    int mode = int(p[0]);
    uint window = min(uint(p[1]), info.filled);
    float3 sum = float3(0.0), hi = float3(0.0), lo = float3(1.0);
    for (uint i = 0; i < window; i++) {
        float3 c = past(hist, info, uv, i).rgb;
        sum += c; hi = max(hi, c); lo = min(lo, c);
    }
    float3 out = mode == 0 ? sum / float(window) : mode == 1 ? hi : lo;
    dst.write(float4(out, 1.0), gid);
}

// p: direction, skew, wobble
kernel void k_rollingShutter(EFFECT_ARGS) {
    GUARD
    bool rows = p[0] < 0.5;
    float pos = rows ? uv.y : uv.x;
    float2 s = uv;
    float jitter = (noise(float2(pos * 40.0, info.time * 3.0)) - 0.5) * p[2] * 0.04;
    if (rows) s.x += jitter; else s.y += jitter;
    dst.write(pastSmooth(hist, info, s, pos * p[1]), gid);
}

// Pixels that differ from last frame's output keep that output, fading by
// the trail length. Still areas match and pass through.
// p: threshold, length
kernel void k_motionTrails(EFFECT_ARGS) {
    GUARD
    float3 cur = src.sample(lin, uv).rgb;
    float3 before = info.hasPrev != 0 ? prev.sample(lin, uv).rgb : cur;
    float w = smoothstep(p[0], p[0] + 0.05, length(before - cur)) * p[1];
    float3 out = mix(cur, before, w);
    accOut.write(float4(out, 1.0), gid);
    dst.write(float4(out, 1.0), gid);
}

// p: segments, delay, rotation, spin
kernel void k_temporalKaleidoscope(EFFECT_ARGS) {
    GUARD
    float aspect = size.x / size.y;
    float2 c = (uv - 0.5) * float2(aspect, 1.0);
    float r = length(c);
    float seg = 2.0 * M_PI_F / max(p[0], 2.0);
    float a = atan2(c.y, c.x) + p[2] * M_PI_F / 180.0 + info.time * p[3] * 2.0;
    a = a - 2.0 * M_PI_F * floor(a / (2.0 * M_PI_F));
    float index = floor(a / seg);
    float local = a - index * seg;
    if (fmod(index, 2.0) >= 1.0) local = seg - local;   // mirror every other slice
    float2 s = float2(cos(local), sin(local)) * r / float2(aspect, 1.0) + 0.5;
    dst.write(past(hist, info, s, uint(index * p[1])), gid);
}

// p: orientation, pattern, amount, frequency, band, speed
kernel void k_scanlineDistortion(EFFECT_ARGS) {
    GUARD
    bool rows = p[0] < 0.5;
    float line = floor((rows ? float(gid.y) : float(gid.x)) / max(p[4], 1.0));
    float lines = (rows ? size.y : size.x) / max(p[4], 1.0);
    float pos = line / lines;
    float t = info.time * p[5];
    int pattern = int(p[1]);
    float o;
    if (pattern == 0) o = sin(pos * p[3] * 6.2832 + t * 6.2832);
    else if (pattern == 1) o = noise(float2(pos * p[3], t)) * 2.0 - 1.0;
    else o = (hash1(line + floor(t * 12.0) * 13.0) * 2.0 - 1.0) * step(0.7, hash1(line * 3.1 + floor(t * 12.0)));
    float2 s = uv;
    if (rows) s.x += o * p[2]; else s.y += o * p[2];
    dst.write(float4(src.sample(mirror, s).rgb, 1.0), gid);
}

// One thread per row (or column). Pixels whose key falls between the two
// thresholds form runs; each run is counting-sorted by key.
// p: direction, key, lower, upper, order
static float sortKey(float3 c, int key) {
    if (key == 0) return luma(c);
    float3 hsv = rgb2hsv(c);
    return key == 1 ? hsv.x : hsv.y;
}

kernel void k_pixelSort(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        constant Info &info [[buffer(1)]],
                        uint line [[thread_position_in_grid]]) {
    bool vertical = p[0] > 0.5;
    uint count = vertical ? info.width : info.height;
    if (line >= count) return;
    uint len = vertical ? info.height : info.width;
    int key = int(p[1]);
    float lo = min(p[2], p[3]), hi = max(p[2], p[3]);
    bool descending = p[4] > 0.5;
    #define AT(i) (vertical ? uint2(line, (i)) : uint2((i), line))
    const uint BINS = 64;
    uint i = 0;
    while (i < len) {
        float4 c = src.read(AT(i));
        float k = sortKey(c.rgb, key);
        if (k < lo || k > hi) { dst.write(c, AT(i)); i++; continue; }
        uint start = i;
        uint bins[BINS];
        for (uint b = 0; b < BINS; b++) bins[b] = 0;
        while (i < len) {
            float kk = sortKey(src.read(AT(i)).rgb, key);
            if (kk < lo || kk > hi) break;
            bins[min(uint(kk * float(BINS)), BINS - 1)]++;
            i++;
        }
        uint run = i - start;
        uint offset = 0;
        for (uint b = 0; b < BINS; b++) { uint n = bins[b]; bins[b] = offset; offset += n; }
        for (uint j = start; j < i; j++) {
            float4 cj = src.read(AT(j));
            uint b = min(uint(sortKey(cj.rgb, key) * float(BINS)), BINS - 1);
            uint at = bins[b]++;
            uint dest = descending ? start + run - 1 - at : start + at;
            dst.write(cj, AT(dest));
        }
    }
}


// p: output, gain, threshold. Output 2 writes the mask to accOut and passes the input through.
kernel void k_frameDifference(EFFECT_ARGS) {
    GUARD
    float3 cur = src.sample(lin, uv).rgb;
    float3 before = past(hist, info, uv, 1).rgb;
    float3 diff = abs(cur - before);
    float amount = max(length(diff) - p[2], 0.0) * p[1];
    int output = int(p[0]);
    if (output == 0) dst.write(float4(saturate(diff * p[1] * step(p[2], length(diff))), 1.0), gid);
    else if (output == 1) dst.write(float4(cur * saturate(amount), 1.0), gid);
    else {
        dst.write(float4(cur, 1.0), gid);
        accOut.write(float4(saturate(amount)), gid);
    }
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
