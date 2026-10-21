#include <metal_stdlib>
using namespace metal;

// Matches Instance in metal.odin.
struct Instance {
    float4 rect;
    float4 uv;
    float4 color;
    float4 border_color;
    float4 clip;
    float corner_radius;
    float border_width;
    float softness;
    uint kind;
    float4 end_color;
    float2 gradient;
};

constant uint kind_solid = 0;
constant uint kind_glyph = 1;
constant uint kind_image = 2;

struct Fragment {
    float4 position [[position]];
    float2 point;
    float2 uv;
    uint instance [[flat]];
};

vertex Fragment vertex_main(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    const device Instance *instances [[buffer(0)]],
    constant float2 &viewport [[buffer(1)]]
) {
    Instance instance = instances[instance_id];
    float2 corner = float2(vertex_id & 1, vertex_id >> 1);
    // One more pixel on each side, so the antialiased edge is drawn.
    float padding = instance.kind == kind_glyph ? 0.0 : instance.softness + 1.0;
    float2 point = mix(instance.rect.xy - padding, instance.rect.zw + padding, corner);
    float2 along = (point - instance.rect.xy) / (instance.rect.zw - instance.rect.xy);

    Fragment output;
    output.position = float4(point / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    output.point = point;
    output.uv = mix(instance.uv.xy, instance.uv.zw, along);
    output.instance = instance_id;
    return output;
}

// Inigo Quilez's signed distance to a rounded box.
float to_box_distance(float2 point, float2 half_size, float radius) {
    float2 q = abs(point) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 fragment_main(
    Fragment input [[stage_in]],
    const device Instance *instances [[buffer(0)]],
    texture2d<float> image [[texture(0)]],
    sampler texture_sampler [[sampler(0)]]
) {
    Instance instance = instances[input.instance];
    float2 point = input.point;

    if (any(point < instance.clip.xy) || any(point > instance.clip.zw)) discard_fragment();

    if (instance.kind == kind_glyph) {
        float coverage = image.sample(texture_sampler, input.uv).r;
        return float4(instance.color.rgb, 1.0) * instance.color.a * coverage;
    }

    float2 half_size = (instance.rect.zw - instance.rect.xy) * 0.5;
    float2 center = (instance.rect.xy + instance.rect.zw) * 0.5;
    float radius = min(instance.corner_radius, min(half_size.x, half_size.y));
    float distance = to_box_distance(point - center, half_size, radius);
    float softness = max(instance.softness, 1.0);
    float coverage = 1.0 - smoothstep(-softness * 0.5, softness * 0.5, distance);

    if (instance.kind == kind_image) {
        float4 pixel = image.sample(texture_sampler, input.uv);
        // The colour tints the picture, as a backdrop darkened behind a page. A gradient fades it out downwards.
        float fade = 1.0;
        if (instance.gradient.y > instance.gradient.x) {
            float along = (point.y - instance.rect.y) / (instance.rect.w - instance.rect.y);
            fade = 1.0 - smoothstep(instance.gradient.x, instance.gradient.y, along);
        }
        return pixel * float4(instance.color.rgb, 1.0) * instance.color.a * coverage * fade;
    }

    float4 color = instance.color;

    if (instance.gradient.y > instance.gradient.x) {
        float along = (point.y - instance.rect.y) / (instance.rect.w - instance.rect.y);
        color = mix(color, instance.end_color, smoothstep(instance.gradient.x, instance.gradient.y, along));
    }

    if (instance.border_width > 0.0) {
        float border = smoothstep(-0.5, 0.5, distance + instance.border_width);
        color = mix(color, instance.border_color, border);
    }

    return float4(color.rgb, 1.0) * color.a * coverage;
}
