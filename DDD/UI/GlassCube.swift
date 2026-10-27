//
//  GlassCube.swift
//  Стеклянный куб навигации: скруглённый куб трассируется во фрагментном шейдере —
//  преломление со своим коэффициентом на каждый канал (дисперсия), полное
//  внутреннее отражение и студийные софтбоксы вокруг.
//

import MetalKit
import SwiftUI
import simd

/// Совпадает с CubeUniforms в шейдере.
struct GlassCubeUniforms {
    var right = SIMD4<Float>(1, 0, 0, 0)
    var up = SIMD4<Float>(0, 1, 0, 0)
    var back = SIMD4<Float>(0, 0, 1, 0)
    /// xyz — зона под курсором, w — 1, если она есть.
    var hovered = SIMD4<Float>(0, 0, 0, 0)
    /// x — ширина кадра в пикселях, y — половина кадра в единицах куба.
    var params = SIMD4<Float>(0, 1.6, 0, 0)
}

struct GlassCubeView: NSViewRepresentable {
    let uniforms: GlassCubeUniforms

    init(right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>, hovered: SIMD3<Float>?, extent: Float) {
        uniforms = GlassCubeUniforms(
            right: SIMD4(right, 0),
            up: SIMD4(up, 0),
            back: SIMD4(back, 0),
            hovered: hovered.map { SIMD4($0, 1) } ?? .zero,
            params: SIMD4(0, extent, 0, 0)
        )
    }

    func makeNSView(context: Context) -> GlassCubeNSView {
        GlassCubeNSView()
    }

    func updateNSView(_ view: GlassCubeNSView, context: Context) {
        view.uniforms = uniforms
        view.needsDisplay = true
    }
}

final class GlassCubeNSView: MTKView, MTKViewDelegate {
    var uniforms = GlassCubeUniforms()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        layer?.isOpaque = false
        delegate = self
        if let device {
            queue = device.makeCommandQueue()
            pipeline = GlassCubeShader.pipeline(device: device, format: colorPixelFormat)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Мышь обрабатывает SwiftUI поверх.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        u.params.x = Float(drawableSize.width)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GlassCubeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

enum GlassCubeShader {
    static func pipeline(device: MTLDevice, format: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassCubeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassCubeFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CubeUniforms {
        float4 right;
        float4 up;
        float4 back;
        float4 hovered;
        float4 params;
    };

    struct Raster {
        float4 position [[position]];
        float2 uv;
    };

    // Один треугольник на весь кадр; uv — от −1 до 1, y вверх.
    vertex Raster glassCubeVertex(uint id [[vertex_id]]) {
        float2 p = float2(float((id << 1) & 2), float(id & 2));
        Raster r;
        r.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        r.uv = p * 2.0 - 1.0;
        return r;
    }

    // Куб ±1: плоская часть ±0.68 плюс скругление 0.32.
    constant float kCore = 0.85;
    constant float kRound = 0.15;

    static float sdCube(float3 p) {
        float3 q = abs(p) - kCore;
        return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - kRound;
    }

    static float3 cubeNormal(float3 p) {
        return normalize(sign(p) * max(abs(p) - kCore, 0.0));
    }

    // Прямоугольный софтбокс в направлении c; halfSize — полуразмеры в тангенсах.
    static float panel(float3 v, float3 c, float2 halfSize, float soft) {
        float k = dot(v, c);
        if (k <= 0.0) return 0.0;
        float3 a = normalize(cross(abs(c.y) > 0.9 ? float3(0, 0, 1) : float3(0, 1, 0), c));
        float3 b = cross(c, a);
        float2 uv = abs(float2(dot(v, a), dot(v, b)) / k);
        float2 inside = 1.0 - smoothstep(halfSize - soft, halfSize + soft, uv);
        return inside.x * inside.y;
    }

    // Студия в осях камеры (x вправо, y вверх, z к зрителю): свет всегда выставлен
    // относительно взгляда, а куб под ним поворачивается.
    static float3 studio(float3 v) {
        float3 col = 0.03 * float3(0.6, 0.7, 0.9) * saturate(v.y * 0.5 + 0.5);
        // Ключевой сверху, большой и мягкий.
        col += float3(1.0, 0.97, 0.92) * 2.0 * panel(v, normalize(float3(0.0, 1.0, 0.2)), float2(1.2, 0.6), 0.35);
        // Подсветка за кубом: сквозь стекло середина светится.
        col += float3(0.85, 0.9, 1.0) * 0.55 * panel(v, normalize(float3(0.35, 0.55, -1.0)), float2(0.55, 0.45), 0.45);
        // Вертикальные полосы по бокам — дают радужные кромки.
        col += float3(0.85, 0.92, 1.0) * 1.6 * panel(v, normalize(float3(-1.0, 0.1, -0.3)), float2(0.25, 1.5), 0.15);
        col += float3(1.0) * 1.2 * panel(v, normalize(float3(1.0, 0.0, -0.1)), float2(0.15, 1.5), 0.12);
        // Тёплый отражатель снизу.
        col += float3(1.0, 0.75, 0.55) * 0.5 * panel(v, normalize(float3(0.0, -1.0, -0.3)), float2(1.2, 0.5), 0.4);
        return col;
    }

    static float3 toView(float3 d, constant CubeUniforms& u) {
        return float3(dot(d, u.right.xyz), dot(d, u.up.xyz), dot(d, u.back.xyz));
    }

    // Цвет (уже умноженный на альфу) и покрытие одного луча.
    static float4 trace(float2 uv, constant CubeUniforms& u) {
        float extent = u.params.y;
        float3 ro = (u.right.xyz * uv.x + u.up.xyz * uv.y) * extent + u.back.xyz * 4.0;
        float3 rd = -u.back.xyz;

        float t = 0.0;
        bool hit = false;
        for (int i = 0; i < 80; i++) {
            float d = sdCube(ro + rd * t);
            if (d < 0.0004) { hit = true; break; }
            t += d;
            if (t > 8.0) break;
        }
        if (!hit) return float4(0.0);

        float3 p = ro + rd * t;
        float3 n = cubeNormal(p);
        float cosi = saturate(-dot(rd, n));
        float fresnel = 0.04 + 0.96 * pow(1.0 - cosi, 5.0);
        float3 reflected = studio(toView(reflect(rd, n), u));

        // Дисперсия: у каждого канала свой коэффициент преломления.
        const float3 iors = float3(1.38, 1.50, 1.62);
        float3 refracted = 0.0;
        for (int c = 0; c < 3; c++) {
            float ior = iors[c];
            float3 dir = refract(rd, n, 1.0 / ior);
            float3 q = p - n * 0.002;
            for (int bounce = 0; bounce < 5; bounce++) {
                float s = 0.0;
                for (int i = 0; i < 48; i++) {
                    float d = -sdCube(q + dir * s);
                    if (d < 0.0004) break;
                    s += d;
                }
                q += dir * s;
                float3 m = -cubeNormal(q);
                float3 out = refract(dir, m, ior);
                if (dot(out, out) < 1e-6) {
                    // Полное внутреннее отражение: луч идёт дальше внутри стекла.
                    dir = reflect(dir, m);
                    q += m * 0.002;
                    continue;
                }
                refracted[c] = studio(toView(out, u))[c];
                break;
            }
        }

        float3 color = mix(refracted * float3(0.95, 0.98, 1.0), reflected, fresnel);

        float alpha = 0.55;
        // Подсветка зоны под курсором: грань, ребро или угол.
        float3 zone = select(float3(0.0), sign(p), abs(p) > 0.55);
        if (u.hovered.w > 0.5 && all(zone == u.hovered.xyz)) {
            color += float3(0.30, 0.84, 0.98) * 0.45;
            alpha = 0.75;
        }

        color = 1.0 - exp(-color * 1.4);
        return float4(color, alpha);
    }

    fragment float4 glassCubeFragment(Raster in [[stage_in]], constant CubeUniforms& u [[buffer(0)]]) {
        // 4 луча на пиксель: гладкий край и тонкие радужные полосы без лесенки.
        float px = 2.0 / max(u.params.x, 1.0);
        float4 sum = 0.0;
        for (int i = 0; i < 4; i++) {
            float2 offset = (float2(float(i & 1), float(i >> 1)) - 0.5) * 0.5 * px;
            sum += trace(in.uv + offset, u);
        }
        return sum / 4.0;
    }
    """
}
