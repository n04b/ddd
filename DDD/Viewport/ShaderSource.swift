//
//  ShaderSource.swift
//  Шейдер компилируется при запуске из исходника: так проекту не нужен
//  отдельный Metal Toolchain, который Xcode 26 скачивает отдельно.
//

enum ShaderSource {
    static let main = """
    #include <metal_stdlib>
    using namespace metal;

    // Совпадает с TriMesh.data: 8 float на вершину (float3 в памяти занимает 16 байт).
    struct MeshVertex {
        float3 position;
        float3 normal;
    };

    // Совпадает с GPUUniforms в Renderer.swift.
    struct Uniforms {
        float4x4 viewProj;
        float4x4 model;
        float4 color;
        float4 cameraPos;
        float4 params;   // x: 1 — освещение, 0 — плоский цвет
    };

    struct RasterVertex {
        float4 position [[position]];
        float3 normal;
        float3 world;
    };

    vertex RasterVertex vmain(uint vid [[vertex_id]],
                              const device MeshVertex* vertices [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
        MeshVertex v = vertices[vid];
        float4 world = u.model * float4(v.position, 1.0);
        RasterVertex out;
        out.position = u.viewProj * world;
        out.normal = (u.model * float4(v.normal, 0.0)).xyz;
        out.world = world.xyz;
        return out;
    }

    fragment float4 fmain(RasterVertex in [[stage_in]],
                          constant Uniforms& u [[buffer(1)]]) {
        if (u.params.x < 0.5) {
            return u.color;
        }
        float3 n = normalize(in.normal);
        float3 v = normalize(u.cameraPos.xyz - in.world);
        if (dot(n, v) < 0.0) {
            n = -n;
        }
        float3 keyLight = normalize(float3(0.35, -0.55, 0.85));
        float3 fillLight = normalize(float3(-0.6, 0.45, 0.25));
        float hemi = 0.5 + 0.5 * n.z;
        float light = 0.30 + 0.20 * hemi
                    + 0.50 * max(dot(n, keyLight), 0.0)
                    + 0.14 * max(dot(n, fillLight), 0.0);
        float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.16;
        float3 c = u.color.rgb * light + rim;
        return float4(c, u.color.a);
    }

    // Маска силуэтов: каждый обводимый слой пишет в свой канал.
    fragment float4 fmask(RasterVertex in [[stage_in]],
                          constant Uniforms& u [[buffer(1)]]) {
        return u.color;
    }

    // Совпадает с ImageUniforms в Renderer.swift.
    struct ImageUniforms {
        float4x4 viewProj;
        float4x4 model;    // квадрат −0.5…0.5 → прямоугольник картинки в мире
        float4 params;     // x: непрозрачность
    };

    struct ImageVertex {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 kQuad[6] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5),
        float2(-0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5)
    };

    // Референс-изображение: два треугольника без буфера вершин; uv (0, 0) — левый верхний угол.
    vertex ImageVertex vimage(uint vid [[vertex_id]],
                              constant ImageUniforms& u [[buffer(1)]]) {
        float2 c = kQuad[vid];
        ImageVertex out;
        out.position = u.viewProj * (u.model * float4(c, 0.0, 1.0));
        out.uv = float2(c.x + 0.5, 0.5 - c.y);
        return out;
    }

    // Текстура с premultiplied alpha: непрозрачность умножает все четыре канала.
    fragment float4 fimage(ImageVertex in [[stage_in]],
                           texture2d<float> image [[texture(0)]],
                           constant ImageUniforms& u [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(8));
        return image.sample(s, in.uv) * u.params.x;
    }

    // Только глубина: плотная картинка заслоняет то, что рисуется после неё (сетку стола).
    fragment float4 fimagedepth(ImageVertex in [[stage_in]],
                                texture2d<float> image [[texture(0)]],
                                constant ImageUniforms& u [[buffer(1)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        if (image.sample(s, in.uv).a * u.params.x < 0.5) {
            discard_fragment();
        }
        return float4(0.0);
    }

    // Совпадает с OutlineUniforms в Renderer.swift.
    struct OutlineUniforms {
        float4 colors[4];  // цвет линии для каждого канала маски
        float4 params;     // x: полуширина линии в пикселях
    };

    struct OutlineVertex {
        float4 position [[position]];
    };

    // Один треугольник на весь экран.
    vertex OutlineVertex voutline(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        OutlineVertex out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Линия по краю каждого канала маски: разница между максимумом и минимумом в окрестности.
    fragment float4 foutline(OutlineVertex in [[stage_in]],
                             texture2d<float> mask [[texture(0)]],
                             constant OutlineUniforms& u [[buffer(0)]]) {
        constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_zero);
        float r = u.params.x;
        float4 center = mask.sample(s, in.position.xy);
        float4 lo = center;
        float4 hi = center;
        for (int i = 0; i < 12; i++) {
            float a = float(i) * (M_PI_F / 6.0);
            float2 d = float2(cos(a), sin(a));
            float4 far = mask.sample(s, in.position.xy + d * r);
            float4 near = mask.sample(s, in.position.xy + d * (r * 0.5));
            lo = min(lo, min(far, near));
            hi = max(hi, max(far, near));
        }
        float4 w = saturate(hi - lo) * float4(u.colors[0].a, u.colors[1].a, u.colors[2].a, u.colors[3].a);
        float total = w.x + w.y + w.z + w.w;
        if (total <= 0.0) {
            discard_fragment();
        }
        float3 rgb = (u.colors[0].rgb * w.x + u.colors[1].rgb * w.y
                    + u.colors[2].rgb * w.z + u.colors[3].rgb * w.w) / total;
        return float4(rgb, max(max(w.x, w.y), max(w.z, w.w)));
    }
    """
}
