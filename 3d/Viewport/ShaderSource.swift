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
    """
}
