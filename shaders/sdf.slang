struct Sdf_Box {
    float2 pos;
    float2 size;
};

static const uint MAX_BOXES = 16;

struct Uniforms {
    float2 resolution;
    float time;
    uint box_count;
    Sdf_Box boxes[MAX_BOXES];
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

float sdf_circle(float2 p, float r) {
    return length(p) - r;
}

float sdf_box(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float smin_cubic(float a, float b, float k) {
     k *= 6.0;
     float h = max(k - abs(a - b), 0.0) / k;
     return min(a, b) - h * h * h * k * (1.0 / 6.0);
}

// >---------------------------------------------------------------------- Scene

float scene(float2 p) {
    float2 c = float2(sin(u.time) * 0.6, 0.0);

    float d = sdf_circle(p - c, 0.3);

    for (uint i = 0; i < u.box_count; i++) {
        Sdf_Box b = u.boxes[i];
        d = smin_cubic(d, sdf_box(p - b.pos, b.size), 0.02);
    }

    return d;
}

[shader("fragment")]
float4 fragment_main(Vertex_Output input) : SV_Target {
    float2 p = (2.0 * input.pos.xy - u.resolution) / u.resolution.y;
    p.y = -p.y;

    float d = scene(p);
    float3 col = d > 0.0 ? float3(0.9, 0.6, 0.6) : float3(0.65, 0.85, 1.0);

    if (d < 0.005 && d > -0.005) {
        col = float3(0.0, 0.0, 0.0);
    }

    return float4(col, 1.0);
}
