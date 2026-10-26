//
//  STLWriter.swift
//  Двоичный STL. Единицы — миллиметры, как ожидают слайсеры.
//

import Foundation

nonisolated enum STLWriter {
    static func binary(_ meshes: [TriMesh]) -> Data {
        var triangles = 0
        for mesh in meshes { triangles += mesh.triangleCount }

        var data = Data()
        data.reserveCapacity(84 + triangles * 50)

        var header = [UInt8](repeating: 0x20, count: 80)
        let title = Array("3d editor MVP binary STL, units: mm".utf8)
        for i in 0..<min(title.count, header.count) { header[i] = title[i] }
        data.append(contentsOf: header)
        appendUInt32(&data, UInt32(triangles))

        let stride = TriMesh.floatsPerVertex
        for mesh in meshes {
            let d = mesh.data
            var i = 0
            while i + stride * 3 <= d.count {
                let a = Vec3(Double(d[i]), Double(d[i + 1]), Double(d[i + 2]))
                let b = Vec3(Double(d[i + stride]), Double(d[i + stride + 1]), Double(d[i + stride + 2]))
                let c = Vec3(Double(d[i + 2 * stride]), Double(d[i + 2 * stride + 1]), Double(d[i + 2 * stride + 2]))
                let cross = (b - a).cross(c - a)
                let n = cross.length > 1e-12 ? cross.normalized : Vec3.zero
                for v in [n, a, b, c] {
                    appendFloat(&data, Float(v.x))
                    appendFloat(&data, Float(v.y))
                    appendFloat(&data, Float(v.z))
                }
                data.append(contentsOf: [0, 0] as [UInt8])
                i += stride * 3
            }
        }
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendFloat(_ data: inout Data, _ value: Float) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
