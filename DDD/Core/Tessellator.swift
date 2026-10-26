//
//  Tessellator.swift
//  Примитивы в полигоны, центр в начале координат локального пространства.
//

import Foundation

nonisolated enum Tessellator {
    static func polygons(for node: Node, draft: Bool = false) -> [CSGPolygon] {
        let s = Vec3(max(node.size.x, 0.01), max(node.size.y, 0.01), max(node.size.z, 0.01))
        switch node.kind {
        case .box:
            if let rounding = node.rounding, !rounding.isEmpty {
                return RoundedBox.polygons(size: s, rounding: rounding, draft: draft)
            }
            return box(size: s)
        case .sphere:
            return sphere(diameter: s.x)
        case .cylinder:
            return cylinder(diameter: s.x, height: s.z)
        case .group:
            return []
        }
    }

    /// Число сегментов окружности: хорда около `chord` мм, кратно 4.
    static func segments(diameter: Double, chord: Double, minimum: Int, maximum: Int) -> Int {
        let raw = Int((Double.pi * diameter / chord).rounded(.up))
        let clamped = min(max(raw, minimum), maximum)
        return (clamped + 3) / 4 * 4
    }

    static func box(size: Vec3) -> [CSGPolygon] {
        let h = size * 0.5
        let faces: [(normal: Vec3, corners: [Vec3])] = [
            (Vec3(1, 0, 0), [Vec3(1, -1, -1), Vec3(1, 1, -1), Vec3(1, 1, 1), Vec3(1, -1, 1)]),
            (Vec3(-1, 0, 0), [Vec3(-1, -1, -1), Vec3(-1, -1, 1), Vec3(-1, 1, 1), Vec3(-1, 1, -1)]),
            (Vec3(0, 1, 0), [Vec3(-1, 1, -1), Vec3(-1, 1, 1), Vec3(1, 1, 1), Vec3(1, 1, -1)]),
            (Vec3(0, -1, 0), [Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(1, -1, 1), Vec3(-1, -1, 1)]),
            (Vec3(0, 0, 1), [Vec3(-1, -1, 1), Vec3(1, -1, 1), Vec3(1, 1, 1), Vec3(-1, 1, 1)]),
            (Vec3(0, 0, -1), [Vec3(-1, -1, -1), Vec3(-1, 1, -1), Vec3(1, 1, -1), Vec3(1, -1, -1)]),
        ]
        var result: [CSGPolygon] = []
        for face in faces {
            let points = face.corners.map { Vec3($0.x * h.x, $0.y * h.y, $0.z * h.z) }
            let normals = [Vec3](repeating: face.normal, count: points.count)
            if let polygon = outward(points, normals: normals) {
                result.append(polygon)
            }
        }
        return result
    }

    static func sphere(diameter: Double) -> [CSGPolygon] {
        let r = diameter / 2
        let slices = segments(diameter: diameter, chord: 1.5, minimum: 24, maximum: 64)
        let stacks = slices / 2

        func direction(_ i: Int, _ j: Int) -> Vec3 {
            let theta = Double(i) / Double(slices) * 2 * Double.pi
            let phi = Double(j) / Double(stacks) * Double.pi
            return Vec3(cos(theta) * sin(phi), sin(theta) * sin(phi), cos(phi))
        }

        var result: [CSGPolygon] = []
        result.reserveCapacity(slices * stacks)
        for i in 0..<slices {
            for j in 0..<stacks {
                var dirs: [Vec3] = [direction(i, j)]
                if j > 0 { dirs.append(direction(i + 1, j)) }
                if j < stacks - 1 { dirs.append(direction(i + 1, j + 1)) }
                dirs.append(direction(i, j + 1))
                let points = dirs.map { $0 * r }
                if let polygon = outward(points, normals: dirs) {
                    result.append(polygon)
                }
            }
        }
        return result
    }

    static func cylinder(diameter: Double, height: Double) -> [CSGPolygon] {
        let r = diameter / 2
        let hz = height / 2
        let slices = segments(diameter: diameter, chord: 1.0, minimum: 24, maximum: 96)

        var ring: [(x: Double, y: Double)] = []
        for i in 0..<slices {
            let a = Double(i) / Double(slices) * 2 * Double.pi
            ring.append((cos(a), sin(a)))
        }

        var result: [CSGPolygon] = []
        result.reserveCapacity(slices + 2)
        for i in 0..<slices {
            let a = ring[i]
            let b = ring[(i + 1) % slices]
            let points = [Vec3(a.x * r, a.y * r, -hz), Vec3(b.x * r, b.y * r, -hz),
                          Vec3(b.x * r, b.y * r, hz), Vec3(a.x * r, a.y * r, hz)]
            let normals = [Vec3(a.x, a.y, 0), Vec3(b.x, b.y, 0), Vec3(b.x, b.y, 0), Vec3(a.x, a.y, 0)]
            if let polygon = outward(points, normals: normals) {
                result.append(polygon)
            }
        }
        let top = ring.map { Vec3($0.x * r, $0.y * r, hz) }
        let bottom = ring.map { Vec3($0.x * r, $0.y * r, -hz) }
        if let polygon = outward(top, normals: [Vec3](repeating: Vec3(0, 0, 1), count: top.count)) {
            result.append(polygon)
        }
        if let polygon = outward(bottom, normals: [Vec3](repeating: Vec3(0, 0, -1), count: bottom.count)) {
            result.append(polygon)
        }
        return result
    }

    /// Строит полигон и разворачивает его наружу. Все примитивы выпуклые и центрированы
    /// в начале координат, поэтому «наружу» — это от центра.
    static func outward(_ points: [Vec3], normals: [Vec3]) -> CSGPolygon? {
        guard points.count >= 3, let plane = CSGPlane.fromPoints(points) else { return nil }
        var center = Vec3.zero
        for p in points { center = center + p }
        center = center / Double(points.count)
        var vertices: [CSGVertex] = []
        vertices.reserveCapacity(points.count)
        for k in 0..<points.count {
            vertices.append(CSGVertex(pos: points[k], normal: normals[k]))
        }
        if plane.normal.dot(center) < 0 {
            vertices.reverse()
            return CSGPolygon(vertices: vertices, plane: plane.flipped())
        }
        return CSGPolygon(vertices: vertices, plane: plane)
    }
}
