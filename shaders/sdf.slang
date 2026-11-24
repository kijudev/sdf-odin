// Must match Sdf_Kind in renderer.odin
static const uint KIND_SPHERE   = 0;
static const uint KIND_BOX      = 1;
static const uint KIND_TORUS    = 2;
static const uint KIND_CAPSULE  = 3;
static const uint KIND_CYLINDER = 4;

// params meaning per kind:
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
    float bound_radius; // sphere around pos containing the whole shape
};

// Must match Light_Kind in renderer.odin
static const uint LIGHT_DIRECTIONAL = 0;
static const uint LIGHT_POINT       = 1;

struct Light {
    float3 pos_or_dir; // directional: normalized direction towards the light, point: position
    uint kind;
    float3 color;      // already multiplied by intensity
    float _pad;
};

// Must match Gpu_Camera in camera.odin
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
    float3 bounds_min; // box around all primitives
    uint light_count;
    float3 bounds_max;
    float _pad1;
    Sdf_Primitive primitives[MAX_PRIMITIVES];
    Light lights[MAX_LIGHTS];
};

[[vk::binding(0, 3)]]
ConstantBuffer<Uniforms> u;

struct Vertex_Output {
    float4 pos : SV_Position;
};

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

// Smooth min that also returns how much of b to blend in (x = distance, y = blend factor).
// Use the blend factor to lerp anything attached to the surfaces, like color.
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
static const float3 GROUND_COLOR  = float3(0.6, 0.6, 0.6);

// Smooth union strength. Shapes only affect each other within 6 * SMOOTH_K,
// and blended surfaces bulge out by at most SMOOTH_K (see SCENE_BOUNDS_MARGIN in renderer.odin)
static const float SMOOTH_K     = 0.25;
static const float BLEND_RANGE  = 6.0 * SMOOTH_K;

struct Surface {
    float dist;
    float3 color;
};

// Primitives only. The ground plane is intersected analytically in fragment_main.
Surface scene_surface(float3 p) {
    Surface s = { 1e10, float3(0.0) };

    for (uint i = 0; i < u.primitive_count; i++) {
        Sdf_Primitive prim = u.primitives[i];

        // The real distance is at least the distance to the bounding sphere. If even that is
        // too far to blend with what we have, this shape can't change the result: skip it.
        float bound = length(p - prim.pos) - prim.bound_radius;
        if (bound > s.dist + BLEND_RANGE) continue;

        float2 r = smin_cubic(s.dist, sdf_primitive(p, prim), SMOOTH_K);
        s.dist  = r.x;
        s.color = lerp(s.color, prim.color, r.y);
    }

    return s;
}

// distance only, used for marching/normals/shadows (the color math gets optimized out)
float scene(float3 p) {
    return scene_surface(p).dist;
}

// >------------------------------------------------------------------ Rendering

static const int   MAX_STEPS = 128;
static const float MAX_DIST  = 50.0;
static const float SURF_EPS  = 0.001;

// Slab test against the scene bounds. Returns (t_enter, t_exit), missed if t_enter > t_exit.
float2 ray_scene_bounds(float3 ro, float3 rd) {
    if (u.primitive_count == 0) return float2(1.0, -1.0);

    float3 inv = 1.0 / rd;
    float3 t0  = (u.bounds_min - ro) * inv;
    float3 t1  = (u.bounds_max - ro) * inv;
    float3 lo  = min(t0, t1);
    float3 hi  = max(t0, t1);
    return float2(max(lo.x, max(lo.y, lo.z)), min(hi.x, min(hi.y, hi.z)));
}

// Ray vs ground plane. Returns distance along ray, or MAX_DIST if it never hits.
float ray_ground(float3 ro, float3 rd) {
    if (rd.y >= 0.0 || ro.y < GROUND_HEIGHT) return MAX_DIST;
    return (GROUND_HEIGHT - ro.y) / rd.y;
}

// Marches only the part of the ray inside the scene bounds, up to t_max.
// Returns distance along ray, or -1 on miss.
float raymarch(float3 ro, float3 rd, float t_max) {
    float2 span = ray_scene_bounds(ro, rd);
    float t     = max(span.x, 0.0);
    float t_end = min(span.y, t_max);

    for (int i = 0; i < MAX_STEPS && t < t_end; i++) {
        float d = scene(ro + rd * t);
        if (d < SURF_EPS * t) return t;
        t += d;
    }

    return -1.0;
}

// tetrahedron technique: 4 samples instead of 6
float3 calc_normal(float3 p) {
    const float2 k = float2(1.0, -1.0);
    const float h = 0.0005;
    return normalize(
        k.xyy * scene(p + k.xyy * h) +
        k.yyx * scene(p + k.yyx * h) +
        k.yxy * scene(p + k.yxy * h) +
        k.xxx * scene(p + k.xxx * h));
}

// 1.0 = lit, 0.0 = in shadow. Only checks up to t_max (the light's distance),
// and only the part of the ray inside the scene bounds can be occluded.
float hard_shadow(float3 ro, float3 rd, float t_max) {
    float2 span = ray_scene_bounds(ro, rd);
    float t     = max(span.x, 0.02);
    float t_end = min(span.y, t_max);

    for (int i = 0; i < 64 && t < t_end; i++) {
        float d = scene(ro + rd * t);
        if (d < SURF_EPS) return 0.0;
        t += d;
    }

    return 1.0;
}

static const float3 AMBIENT_COLOR = float3(0.15, 0.2, 0.3);

float3 shade(float3 p, float3 n, float3 albedo) {
    float3 light = AMBIENT_COLOR * (0.5 + 0.5 * n.y); // sky fill, brighter facing up

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
        if (n_dot_l <= 0.0) continue; // facing away, no need for a shadow ray

        float shadow = hard_shadow(p + n * 0.002, to_light, light_dist);
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

    float3 sky = lerp(float3(0.9, 0.85, 0.95), float3(0.45, 0.55, 0.8), saturate(rd.y * 2.0));
    float3 col = sky;

    // ground is hit analytically, then objects are only marched up to it
    float t_ground = ray_ground(ro, rd);
    float t_obj    = raymarch(ro, rd, t_ground);

    bool  hit_obj = t_obj > 0.0;
    float t       = hit_obj ? t_obj : t_ground;

    if (t < MAX_DIST) {
        float3 p = ro + rd * t;
        float3 n      = hit_obj ? calc_normal(p) : float3(0.0, 1.0, 0.0);
        float3 albedo = hit_obj ? scene_surface(p).color : GROUND_COLOR;

        col = shade(p, n, albedo);

        // fade to sky with distance
        col = lerp(col, sky, 1.0 - exp(-0.002 * t * t));
    }

    col = pow(col, 1.0 / 2.2); // gamma
    return float4(col, 1.0);
}
