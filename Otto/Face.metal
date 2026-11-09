// One pip face: signed-distance solids, raymarched. A port of design/multi-otto/faces/src/face.js;
// keep the numbers in step with it. Faces.swift fills FaceUniforms.
#include <metal_stdlib>
using namespace metal;

struct FaceUniforms {
    int shape, shape2, arc, n;   // arc: 0 capsule eyes, 1 arcs up, -1 arcs down; n: samples per pixel side
    float3 albedo, pose;         // pose: pitch, yaw, roll
    float4 e0, e1;               // eye: x, y, tilt, half length
    float2 er, eo;               // eye radii; per-solid eye offset
    float b, morph, res, bend;   // blink 0 open to 1 closed; shape to shape2; texture side in pixels
};

// Everything the distance field reads, passed down instead of GLSL's globals.
struct Scene { FaceUniforms u; float3x3 rot; };

static constant float3 CENTRE = float3(0., -.08, 0.), RO = float3(0., 0., 6.5);
static constant float PHI = 1.618034;

static float3 key() { return normalize(float3(-.5, .78, .62)); }
static float3 rim() { return normalize(float3(.72, .5, -.5)); }

static float smax(float a, float b, float k) { float h = max(k - abs(a - b), 0.) / k; return max(a, b) + h * h * k * .25; }

static float solidOf(int S, float3 p) {
    if (S == 0) return length(p) - .88;                                                // sphere
    if (S == 1) { float3 q = abs(p) - .33; return length(max(q, 0.)) + min(max(q.x, max(q.y, q.z)), 0.) - .37; }  // rounded cube
    if (S == 2) { float3 q = p; q.x -= clamp(q.x, -.33, .33); return length(q) - .55; } // capsule on its side
    if (S == 3) {                                                                      // gumdrop
        float2 q = float2(length(p.xz), p.y + .62);
        float r1 = .76, r2 = .42, h = .9, b = (r1 - r2) / h, a = sqrt(1. - b * b), k = dot(q, float2(-b, a));
        float d = k < 0. ? length(q) - r1 : k > a * h ? length(q - float2(0., h)) - r2 : dot(q, float2(a, b)) - r1;
        return smax(d, -(p.y + .72), .36);
    }
    if (S == 4) {                                                                      // soft faceted gem
        float s = 0.;
        const float3 n[6] = { float3(0., 1., PHI), float3(0., -1., PHI), float3(1., PHI, 0.), float3(-1., PHI, 0.), float3(PHI, 0., 1.), float3(PHI, 0., -1.) };
        for (int i = 0; i < 6; i++) s += pow(abs(dot(p, normalize(n[i]))), 11.);
        return pow(s, 1. / 11.) - .78;
    }
    if (S == 5) { float2 d = float2(length(p.xz) - .46, abs(p.y) - .2); return min(max(d.x, d.y), 0.) + length(max(d, 0.)) - .38; }  // soft drum
    float e = 5.5; float3 q = abs(p) * .57735;                                         // soft diamond
    return pow(pow(q.x + q.y + q.z, e) + pow(abs(q.x + q.y - q.z), e) + pow(abs(q.x - q.y + q.z), e) + pow(abs(-q.x + q.y + q.z), e), 1. / e) - .64;
}
static float solid(const Scene s, float3 p) {
    float a = solidOf(s.u.shape, p);
    return s.u.morph > 0. ? mix(a, solidOf(s.u.shape2, p), s.u.morph) : a;
}

static float arcEye(float2 q, float w, float s, float r) {
    q.x = abs(q.x);
    float rc = (w * w + s * s) / (2. * s);
    float2 cc = float2(0., s - rc), a = q - cc, e = float2(w, 0.) - cc;
    float d = a.x * e.y < a.y * e.x ? abs(length(a) - rc) : length(q - float2(w, 0.));
    return d - r;
}
static float eye1(const Scene s, float2 p, float4 e, float r) {
    float2 q = p - e.xy;
    float a = e.z * (1. - s.u.b), c = cos(a), si = sin(a);   // a closing eye levels out, flattens and widens a little
    q = float2(c * q.x + si * q.y, -si * q.x + c * q.y);
    if (s.u.arc != 0) { q.y *= float(s.u.arc); return arcEye(q, e.w, max(.075 * s.u.bend, .001), r); }
    float2 h = mix(float2(r, e.w + r), float2(r * 1.25, (e.w + r) * .2), s.u.b);
    float rc = min(h.x, h.y);
    float2 d = abs(q) - h + rc;
    return length(max(d, 0.)) + min(max(d.x, d.y), 0.) - rc;
}
static float eyes(const Scene s, float2 p) { p -= s.u.eo; return min(eye1(s, p, s.u.e0, s.u.er.x), eye1(s, p, s.u.e1, s.u.er.y)); }

static float2 scene(const Scene s, float3 w) {   // x: distance, y: 1 on the eye glass
    float3 p = s.rot * (w - CENTRE);
    float b = solid(s, p), e = max(eyes(s, p.xy), -p.z);
    float socket = max(e - .016, -(b + .07));
    float body = smax(b, -socket, .05);
    float glass = max(e, b + .03 - .022 * sqrt(clamp(-e / .1, 0., 1.)));
    return glass < body ? float2(glass, 1.) : float2(body, 0.);
}
static float3 normalAt(const Scene s, float3 p) {
    float2 e = float2(.0012, -.0012);
    return normalize(e.xyy * scene(s, p + e.xyy).x + e.yyx * scene(s, p + e.yyx).x + e.yxy * scene(s, p + e.yxy).x + e.xxx * scene(s, p + e.xxx).x);
}
static float shadow(const Scene s, float3 p, float3 l, float k) {
    float res = 1., t = .02;
    for (int i = 0; i < 48 && t < 4.; i++) {
        float h = scene(s, p + l * t).x;
        res = min(res, k * h / t);
        if (res < .001) break;
        t += clamp(h * .8, .012, .25);
    }
    res = clamp(res, 0., 1.);
    return res * res * (3. - 2. * res);
}
static float occlusion(const Scene s, float3 p, float3 n) {
    float a = 0., w = 1.;
    for (int i = 1; i < 6; i++) { float d = float(i) * .07; a += w * (d - scene(s, p + n * d).x); w *= .6; }
    return clamp(1. - 1.5 * a, 0., 1.);
}
static float ggx(float nh, float a) { float a2 = a * a, d = nh * nh * (a2 - 1.) + 1.; return a2 / (3.14159 * d * d); }

static float3 matte(const Scene s, float3 p, float3 n, float3 v) {
    float3 albedo = s.u.albedo, KEY = key(), RIM = rim();
    float ao = occlusion(s, p, n), ndl = dot(n, KEY), sh = shadow(s, p + n * .012, KEY, 9.);
    float wrap = pow(clamp((ndl + .22) / 1.22, 0., 1.), 1.25);
    float3 h = normalize(KEY + v);
    // light that bleeds past the terminator picks up the material's own colour, as soft plastic does
    float3 deep = pow(albedo, float3(1.5));
    float3 c = albedo * float3(1.02, .99, .94) * 1.95 * wrap * sh;
    c += deep * float3(.95, .6, .45) * .55 * smoothstep(-.35, .25, ndl) * (1. - smoothstep(.0, .55, ndl * sh));
    c += albedo * float3(.72, .8, 1.) * .62 * (.55 + .45 * n.y) * ao;   // sky fill
    c += deep * .38 * clamp(.5 - .5 * n.y, 0., 1.) * ao;                // page bounce
    float f = pow(1. - clamp(dot(n, v), 0., 1.), 3.2);
    c += float3(1., .97, .93) * f * .85 * clamp(dot(n, RIM) * .75 + .4, 0., 1.) * ao;
    c += float3(1.) * ggx(clamp(dot(n, h), 0., 1.), .3) * .05 * sh * clamp(ndl, 0., 1.);
    return c;
}
static float3 glossy(const Scene s, float3 p, float3 n, float3 v) {
    float3 r = reflect(-v, n);
    float f = .04 + .96 * pow(1. - clamp(dot(n, v), 0., 1.), 5.);
    float3 env = float3(.03, .03, .036) + float3(.14, .15, .18) * smoothstep(-.2, 1., r.y);
    env += float3(1.5) * smoothstep(.9, .97, dot(r, key()));
    return float3(.006, .005, .005) + env * (f + .1) * occlusion(s, p, n);
}

static float4 trace(const Scene s, float3 rd) {
    float t = 4.;
    for (int i = 0; i < 128 && t < 9.; i++) {
        float2 h = scene(s, RO + rd * t);
        if (h.x < .0006) {
            float3 p = RO + rd * t, n = normalAt(s, p), v = -rd;
            return float4(h.y > .5 ? glossy(s, p, n, v) : matte(s, p, n, v), 1.);
        }
        t += h.x * .8;
    }
    return float4(0.);
}

vertex float4 faceVertex(uint id [[vertex_id]]) {
    const float2 p[3] = { float2(-1., -1.), float2(3., -1.), float2(-1., 3.) };
    return float4(p[id], 0., 1.);
}

fragment float4 faceFragment(float4 pos [[position]], constant FaceUniforms& u [[buffer(0)]]) {
    float3 si = sin(u.pose), c0 = cos(u.pose);
    float3x3 rot = float3x3(float3(c0.z, si.z, 0.), float3(-si.z, c0.z, 0.), float3(0., 0., 1.))
                 * float3x3(float3(c0.y, 0., -si.y), float3(0., 1., 0.), float3(si.y, 0., c0.y))
                 * float3x3(float3(1., 0., 0.), float3(0., c0.x, si.x), float3(0., -si.x, c0.x));
    Scene s = { u, rot };
    // GL's window origin is bottom-left, Metal's top-left.
    float2 frag = float2(pos.x, u.res - pos.y);
    float4 sum = float4(0.);
    for (int y = 0; y < u.n; y++) for (int x = 0; x < u.n; x++) {
        float2 uv = (frag - .5 + (float2(x, y) + .5) / float(u.n)) / (u.res * .5) - 1.;
        float4 c = trace(s, normalize(float3(uv, 0.) - RO));
        sum += float4(c.rgb * c.a, c.a);
    }
    sum /= float(u.n * u.n);
    if (sum.a < .0001) return float4(0.);
    float3 c = sum.rgb / sum.a;
    c = c * (1. + c / 14.) / (1. + c / 3.2) * 1.28;   // soft shoulder that keeps the hue
    c = pow(clamp(c, 0., 1.), float3(1. / 2.2));
    return float4(c * sum.a, sum.a);
}
