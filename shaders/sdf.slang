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

struct Uniforms {
    float2 resolution;
    float time;
    uint primitive_count;
    Gpu_Camera camera;
    Sdf_Primitive primitives[MAX_PRIMITIVES];
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

struct Surface {
    float dist;
    float3 color;
};

Surface scene_surface(float3 p) {
    Surface s = { 1e10, float3(0.0) };

    for (uint i = 0; i < u.primitive_count; i++) {
        Sdf_Primitive prim = u.primitives[i];
        float2 r = smin_cubic(s.dist, sdf_primitive(p, prim), 0.05);
        s.dist  = r.x;
        s.color = lerp(s.color, prim.color, r.y);
    }

    float ground = sdf_plane(p, GROUND_HEIGHT);
    if (ground < s.dist) {
        s.dist  = ground;
        s.color = GROUND_COLOR;
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

// returns distance along ray, or -1 on miss
float raymarch(float3 ro, float3 rd) {
    float t = 0.0;

    for (int i = 0; i < MAX_STEPS && t < MAX_DIST; i++) {
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

// 1.0 = lit, 0.0 = in shadow
float hard_shadow(float3 ro, float3 rd) {
    float t = 0.02;
    for (int i = 0; i < 64 && t < MAX_DIST; i++) {
        float d = scene(ro + rd * t);
        if (d < SURF_EPS) return 0.0;
        t += d;
    }
    return 1.0;
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

    float t = raymarch(ro, rd);
    if (t > 0.0) {
        float3 p = ro + rd * t;
        float3 n = calc_normal(p);

        float3 light_dir = normalize(float3(0.6, 0.8, 0.4));
        float diffuse = saturate(dot(n, light_dir)) * hard_shadow(p + n * 0.002, light_dir);
        float ambient = 0.5 + 0.5 * n.y; // brighter facing up

        float3 albedo = scene_surface(p).color;

        col = albedo * (diffuse * float3(1.0, 0.95, 0.85) + ambient * float3(0.15, 0.2, 0.3));

        // fade to sky with distance
        col = lerp(col, sky, 1.0 - exp(-0.002 * t * t));
    }

    col = pow(col, 1.0 / 2.2); // gamma
    return float4(col, 1.0);
}
