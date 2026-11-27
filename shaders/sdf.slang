static const uint KIND_SPHERE   = 0;
static const uint KIND_BOX      = 1;
static const uint KIND_TORUS    = 2;
static const uint KIND_CAPSULE  = 3;
static const uint KIND_CYLINDER = 4;

// Params meaning per kind:
//   sphere:   x = radius
//   box:      xyz = half extents
//   torus:    x = major radius, y = minor radius
//   capsule:  x = half height, y = radius (vertical)
//   cylinder: x = half height, y = radius (vertical)
struct Sdf_Primitive {
    float3 pos;
    uint kind;
    float4 params;
    float3 color;
    float bound_radius;
};

static const uint LIGHT_DIRECTIONAL = 0;
static const uint LIGHT_POINT       = 1;

struct Light {
    float3 pos_or_dir;
    uint kind;
    float3 color;
    float _pad;
};

struct Gpu_Camera {
    float3 pos;
    float focal_length;
    float3 forward;
    float _pad0;
    float3 right;
    float _pad1;
    float3 up;
    float _pad2;
};

static const uint MAX_PRIMITIVES = 32;
static const uint MAX_LIGHTS     = 8;

struct Uniforms {
    float2 resolution;
    float time;
    uint primitive_count;
    Gpu_Camera camera;
    float3 bounds_min;
    uint light_count;
    float3 bounds_max;
    float _pad1;
    Sdf_Primitive primitives[MAX_PRIMITIVES];
    Light lights[MAX_LIGHTS];
};

// SDL3's GPU API pushes uniforms to descriptor set 3, slot 0.
[[vk::binding(0, 3)]]
ConstantBuffer<Uniforms> u;

struct Vertex_Output {
    float4 pos : SV_Position;
};

// The triangle is bigger than the screen.
// One triangle, not two creating a quad.
// A quad would resolve in a diagonal seam going through the middle of the screen.
// Pixels on that seam would be shaded twice, which is unwanted.
[shader("vertex")]
Vertex_Output vertex_main(uint vid : SV_VulkanVertexID) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    Vertex_Output o;
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// >------------------------------------------------------------- SDF Primitives

float sdf_sphere(float3 p, float r) {
    return length(p) - r;
}

float sdf_box(float3 p, float3 b) {
    float3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

float sdf_torus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

float sdf_capsule(float3 p, float h, float r) {
    p.y -= clamp(p.y, -h, h);
    return length(p) - r;
}

float sdf_cylinder(float3 p, float h, float r) {
    float2 d = abs(float2(length(p.xz), p.y)) - float2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

float sdf_plane(float3 p, float height) {
    return p.y - height;
}

float2 smin_cubic(float a, float b, float k) {
    k *= 6.0;
    float h = max(k - abs(a - b), 0.0) / k;
    float m = h * h * h * 0.5;
    float s = m * k * (1.0 / 3.0);
    return a < b ? float2(a - s, m) : float2(b - s, 1.0 - m);
}

float sdf_primitive(float3 p, Sdf_Primitive prim) {
    float3 q = p - prim.pos;
    float4 a = prim.params;

    switch (prim.kind) {
    case KIND_SPHERE:   return sdf_sphere(q, a.x);
    case KIND_BOX:      return sdf_box(q, a.xyz);
    case KIND_TORUS:    return sdf_torus(q, a.xy);
    case KIND_CAPSULE:  return sdf_capsule(q, a.x, a.y);
    case KIND_CYLINDER: return sdf_cylinder(q, a.x, a.y);
    default:            return 1e10;
    }
}

// >---------------------------------------------------------------------- Scene

static const float  GROUND_HEIGHT = 0.0;
static const float3 GROUND_COLOR  = float3(0.1, 0.4, 0.1);

static const float SMOOTH_K     = 0.1;
static const float BLEND_RANGE  = 6.0 * SMOOTH_K;

struct Surface {
    float dist;
    float3 color;
};

// Calculates blended distance + blended color of the whole scene.
Surface scene_surface(float3 p) {
    Surface s = { 1e10, float3(0.0) };

    for (uint i = 0; i < u.primitive_count; i++) {
        Sdf_Primitive prim = u.primitives[i];

        // This is an exact optimization.
        // Shapes which influence cannot be seen are skipped.
        float bound = length(p - prim.pos) - prim.bound_radius;
        if (bound > s.dist + BLEND_RANGE) continue;

        // Smooth minimum of shapes. Shapes only combine for now.
        float2 r = smin_cubic(s.dist, sdf_primitive(p, prim), SMOOTH_K);
        s.dist  = r.x;

        // Linear interpolation of colors.
        s.color = lerp(s.color, prim.color, r.y);
    }

    return s;
}

// Calculates scene distance only.
float scene_distance(float3 p) {
    float dist = 1e10;

   
    for (uint i = 0; i < u.primitive_count; i++) {
        Sdf_Primitive prim = u.primitives[i];

        // This is an exact optimization.
        // Shapes which influence cannot be seen are skipped.
        float bound = length(p - prim.pos) - prim.bound_radius;
        if (bound > dist + BLEND_RANGE) continue;

        // Smooth minimum of shapes. Shapes only combine for now.
        float2 r = smin_cubic(dist, sdf_primitive(p, prim), SMOOTH_K);
        dist  = r.x;
    }

    return dist;
}

// >------------------------------------------------------------------ Rendering

static const int   MAX_STEPS = 128;
static const float MAX_DIST  = 50.0;
static const float SURF_EPS  = 0.001;

// Ray-box intersection using the slab method.
// Takes ray origin - ro, and ray direction - rd.
// Returns (enter, exit) on the axis of the ray.
float2 ray_scene_bounds(float3 ro, float3 rd) {
    if (u.primitive_count == 0) return float2(1.0, -1.0);

    float3 inv = 1.0 / rd;
    float3 t0  = (u.bounds_min - ro) * inv;
    float3 t1  = (u.bounds_max - ro) * inv;
    float3 lo  = min(t0, t1);
    float3 hi  = max(t0, t1);

    return float2(
        max(lo.x, max(lo.y, lo.z)),
        min(hi.x, min(hi.y, hi.z))
    );
}

// Ray-plane intersection.
float ray_ground(float3 ro, float3 rd) {
    if (abs(rd.y) < 1e-6) return MAX_DIST;
    float t = (GROUND_HEIGHT - ro.y) / rd.y;
    return t > 0.0 ? t : MAX_DIST;
}

// Standard sphere-based ray marching.
// Takes in ray origin, ray direction and maximum direction along the ray.
// Returns the direction along the ray at which at had stopped
// or -1.0 if the ray did not hit anything.
float raymarch(float3 ro, float3 rd, float t_max) {
    float2 span = ray_scene_bounds(ro, rd);
    float t     = max(span.x, 0.0);
    float t_end = min(span.y, t_max);

    for (int i = 0; i < MAX_STEPS && t < t_end; i++) {
        float d = scene_distance(ro + rd * t);
        if (d < SURF_EPS * t) return t;
        t += d;
    }

    return -1.0;
}

// Calculates normals of a point on the surface (or close to) an SDF.
// The normal SDF is the gradient of the distance.
// This uses a tetrahedron trick - uses 4 samples instead of 6.
float3 calc_normal(float3 p) {
    const float2 k = float2(1.0, -1.0);
    const float h = 0.0005;
    return normalize(
        k.xyy * scene_distance(p + k.xyy * h) +
        k.yyx * scene_distance(p + k.yyx * h) +
        k.yxy * scene_distance(p + k.yxy * h) +
        k.xxx * scene_distance(p + k.xxx * h));
}

// Higher = sharper shadow edges.
static const float SHADOW_K = 16.0;

// Like `raymarch` this is also marching but from surface point towards the light.
// So this has to be performed for every light source.
float soft_shadow(float3 ro, float3 rd, float t_max) {
    float2 span = ray_scene_bounds(ro, rd);
    float t     = max(span.x, 0.02);
    float t_end = min(span.y, t_max);
    float res   = 1.0;

    for (int i = 0; i < 64 && t < t_end; i++) {
        float d = scene_distance(ro + rd * t);
        if (d < SURF_EPS) return 0.0;

        // d / t is roughly the angle by which the ray missed a surface.
        // The closer the near-miss, the darker the penumbra.
        res = min(res, SHADOW_K * d / t);
        t += d;
    }

    return smoothstep(0.0, 1.0, res);
}

static const float3 SKY_HORIZON = float3(0.75, 0.85, 0.95);
static const float3 SKY_ZENITH  = float3(0.20, 0.40, 0.85);
static const float  AMBIENT     = 0.3;

float3 sky_gradient(float3 dir) {
    // sqrt makes the horizon band thin, so most of the sky is blue.
    return lerp(SKY_HORIZON, SKY_ZENITH, sqrt(saturate(dir.y)));
}

float3 sky_color(float3 rd) {
    float3 col = sky_gradient(rd);

    for (uint i = 0; i < u.light_count; i++) {
        Light l = u.lights[i];
        if (l.kind != LIGHT_DIRECTIONAL) continue;

        // 1 when looking straight at the sun. High power = small disk, low power = wide glow.
        float s = saturate(dot(rd, l.pos_or_dir));
        col += l.color * (pow(s, 800.0) + 0.15 * pow(s, 6.0));
    }

    return col;
}

float3 shade(float3 p, float3 n, float3 albedo) {
    // Ambient is light coming from the sky in the direction of the normal, so shadows
    // pick up a blue tint. Faces pointing down get less of it.
    float3 light = AMBIENT * sky_gradient(n) * (0.5 + 0.5 * n.y);

    for (uint i = 0; i < u.light_count; i++) {
        Light l = u.lights[i];

        float3 to_light    = l.pos_or_dir;
        float  attenuation = 1.0;
        float  light_dist  = MAX_DIST;

        if (l.kind == LIGHT_POINT) {
            float3 v    = l.pos_or_dir - p;
            light_dist  = length(v);
            to_light    = v / light_dist;
            attenuation = 1.0 / (1.0 + light_dist * light_dist);
        }

        float n_dot_l = dot(n, to_light);
        if (n_dot_l <= 0.0) continue;

        float shadow = soft_shadow(p + n * 0.002, to_light, light_dist);
        light += l.color * n_dot_l * attenuation * shadow;
    }

    return albedo * light;
}

[shader("fragment")]
float4 fragment_main(Vertex_Output input) : SV_Target {
    float2 uv = (2.0 * input.pos.xy - u.resolution) / u.resolution.y;
    uv.y = -uv.y;

    Gpu_Camera cam = u.camera;
    float3 ro = cam.pos;
    float3 rd = normalize(uv.x * cam.right + uv.y * cam.up + cam.focal_length * cam.forward);

    float3 sky = sky_color(rd);
    float3 col = sky;

    float t_ground = ray_ground(ro, rd);
    float t_obj    = raymarch(ro, rd, t_ground);

    bool  hit_obj = t_obj > 0.0;
    float t       = hit_obj ? t_obj : t_ground;

    if (t < MAX_DIST) {
        float3 p      = ro + rd * t;
        float3 n      = hit_obj ? calc_normal(p) : float3(0.0, 1.0, 0.0);
        float3 albedo = hit_obj ? scene_surface(p).color : GROUND_COLOR;

        col = shade(p, n, albedo);
        col = lerp(col, sky, 1.0 - exp(-0.002 * t * t));
    }

    col = pow(col, 1.0 / 2.2);
    return float4(col, 1.0);
}
