//
//  CSG.swift
//  Булевы операции над полигональными телами через BSP-деревья
//  (порт алгоритма csg.js Эвана Уоллеса, MIT).
//
//  Это временное ядро для MVP: точное для плоских граней, кривые поверхности
//  аппроксимируются. Интерфейс GeometryKernel позволит потом заменить его на
//  OpenCascade или Manifold, не трогая UI.
//

import Foundation

nonisolated struct CSGVertex: Sendable {
    var pos: Vec3
    var normal: Vec3

    func flipped() -> CSGVertex {
        CSGVertex(pos: pos, normal: -normal)
    }

    func interpolated(_ other: CSGVertex, _ t: Double) -> CSGVertex {
        CSGVertex(pos: pos.lerp(other.pos, t), normal: normal.lerp(other.normal, t))
    }
}

nonisolated enum SplitResult {
    case coplanarFront
    case coplanarBack
    case front
    case back
    case spanning(CSGPolygon?, CSGPolygon?)
}

nonisolated struct CSGPlane: Sendable {
    var normal: Vec3
    var w: Double

    /// Допуск классификации точки относительно плоскости, мм.
    static let epsilon = 1e-5

    func flipped() -> CSGPlane {
        CSGPlane(normal: -normal, w: -w)
    }

    /// Плоскость по контуру методом Ньюэлла; нормаль по правилу правой руки.
    static func fromPoints(_ points: [Vec3]) -> CSGPlane? {
        guard points.count >= 3 else { return nil }
        var n = Vec3.zero
        var c = Vec3.zero
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
            c = c + a
        }
        let len = n.length
        guard len > 1e-12 else { return nil }
        let unit = n / len
        c = c / Double(points.count)
        return CSGPlane(normal: unit, w: unit.dot(c))
    }

    func split(_ polygon: CSGPolygon) -> SplitResult {
        let eps = CSGPlane.epsilon
        let count = polygon.vertices.count
        var types = [Int](repeating: 0, count: count)
        var polygonType = 0
        for i in 0..<count {
            let t = normal.dot(polygon.vertices[i].pos) - w
            let type = t < -eps ? 2 : (t > eps ? 1 : 0)
            types[i] = type
            polygonType |= type
        }

        switch polygonType {
        case 0:
            return normal.dot(polygon.plane.normal) > 0 ? .coplanarFront : .coplanarBack
        case 1:
            return .front
        case 2:
            return .back
        default:
            var f: [CSGVertex] = []
            var b: [CSGVertex] = []
            f.reserveCapacity(count + 2)
            b.reserveCapacity(count + 2)
            for i in 0..<count {
                let j = (i + 1) % count
                let ti = types[i]
                let tj = types[j]
                let vi = polygon.vertices[i]
                let vj = polygon.vertices[j]
                if ti != 2 { f.append(vi) }
                if ti != 1 { b.append(vi) }
                if (ti | tj) == 3 {
                    let denom = normal.dot(vj.pos - vi.pos)
                    let t = denom != 0 ? (w - normal.dot(vi.pos)) / denom : 0
                    let v = vi.interpolated(vj, t)
                    f.append(v)
                    b.append(v)
                }
            }
            // Куски лежат в плоскости исходного полигона: наследуем её,
            // чтобы не пересчитывать нормаль по возможно вырожденным точкам.
            let fp = f.count >= 3 ? CSGPolygon(vertices: f, plane: polygon.plane) : nil
            let bp = b.count >= 3 ? CSGPolygon(vertices: b, plane: polygon.plane) : nil
            return .spanning(fp, bp)
        }
    }
}

/// Выпуклый плоский полигон. Порядок вершин согласован с plane (против часовой стрелки снаружи).
nonisolated struct CSGPolygon: Sendable {
    var vertices: [CSGVertex]
    var plane: CSGPlane

    func flipped() -> CSGPolygon {
        CSGPolygon(vertices: vertices.reversed().map { $0.flipped() }, plane: plane.flipped())
    }
}

nonisolated final class BSPNode {
    var plane: CSGPlane?
    var front: BSPNode?
    var back: BSPNode?
    var polygons: [CSGPolygon] = []

    init(_ polygons: [CSGPolygon] = []) {
        if !polygons.isEmpty {
            build(polygons)
        }
    }

    /// Меняет местами «внутри» и «снаружи».
    func invert() {
        polygons = polygons.map { $0.flipped() }
        plane = plane?.flipped()
        front?.invert()
        back?.invert()
        let tmp = front
        front = back
        back = tmp
    }

    /// Убирает из списка части полигонов, лежащие внутри этого дерева.
    func clipPolygons(_ input: [CSGPolygon]) -> [CSGPolygon] {
        guard let plane else { return input }
        var f: [CSGPolygon] = []
        var b: [CSGPolygon] = []
        for polygon in input {
            switch plane.split(polygon) {
            case .coplanarFront, .front:
                f.append(polygon)
            case .coplanarBack, .back:
                b.append(polygon)
            case .spanning(let fp, let bp):
                if let fp { f.append(fp) }
                if let bp { b.append(bp) }
            }
        }
        if let front {
            f = front.clipPolygons(f)
        }
        if let back {
            b = back.clipPolygons(b)
        } else {
            b.removeAll()
        }
        return f + b
    }

    /// Убирает из этого дерева всё, что лежит внутри другого.
    func clip(to other: BSPNode) {
        polygons = other.clipPolygons(polygons)
        front?.clip(to: other)
        back?.clip(to: other)
    }

    func allPolygons() -> [CSGPolygon] {
        var result: [CSGPolygon] = []
        collect(into: &result)
        return result
    }

    private func collect(into result: inout [CSGPolygon]) {
        result.append(contentsOf: polygons)
        front?.collect(into: &result)
        back?.collect(into: &result)
    }

    func build(_ input: [CSGPolygon]) {
        guard !input.isEmpty else { return }
        if plane == nil {
            plane = input[0].plane
        }
        guard let plane else { return }
        var f: [CSGPolygon] = []
        var b: [CSGPolygon] = []
        for polygon in input {
            switch plane.split(polygon) {
            case .coplanarFront, .coplanarBack:
                polygons.append(polygon)
            case .front:
                f.append(polygon)
            case .back:
                b.append(polygon)
            case .spanning(let fp, let bp):
                if let fp { f.append(fp) }
                if let bp { b.append(bp) }
            }
        }
        if !f.isEmpty {
            let node = front ?? BSPNode()
            front = node
            node.build(f)
        }
        if !b.isEmpty {
            let node = back ?? BSPNode()
            back = node
            node.build(b)
        }
    }
}

nonisolated enum CSG {
    static func union(_ a: [CSGPolygon], _ b: [CSGPolygon]) -> [CSGPolygon] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let ta = BSPNode(a)
        let tb = BSPNode(b)
        ta.clip(to: tb)
        tb.clip(to: ta)
        tb.invert()
        tb.clip(to: ta)
        tb.invert()
        ta.build(tb.allPolygons())
        return ta.allPolygons()
    }

    static func subtract(_ a: [CSGPolygon], _ b: [CSGPolygon]) -> [CSGPolygon] {
        if a.isEmpty || b.isEmpty { return a }
        let ta = BSPNode(a)
        let tb = BSPNode(b)
        ta.invert()
        ta.clip(to: tb)
        tb.clip(to: ta)
        tb.invert()
        tb.clip(to: ta)
        tb.invert()
        ta.build(tb.allPolygons())
        ta.invert()
        return ta.allPolygons()
    }

    static func intersect(_ a: [CSGPolygon], _ b: [CSGPolygon]) -> [CSGPolygon] {
        if a.isEmpty || b.isEmpty { return [] }
        let ta = BSPNode(a)
        let tb = BSPNode(b)
        ta.invert()
        tb.clip(to: ta)
        tb.invert()
        ta.clip(to: tb)
        tb.clip(to: ta)
        ta.build(tb.allPolygons())
        ta.invert()
        return ta.allPolygons()
    }

    static func bounds(of polygons: [CSGPolygon]) -> AABB {
        var box = AABB.empty
        for polygon in polygons {
            for v in polygon.vertices { box.include(v.pos) }
        }
        return box
    }

    static func transformed(_ polygons: [CSGPolygon], by pose: Pose) -> [CSGPolygon] {
        if pose.isIdentity { return polygons }
        return polygons.map { polygon in
            let n = pose.applyDir(polygon.plane.normal)
            let plane = CSGPlane(normal: n, w: polygon.plane.w + n.dot(pose.translation))
            let vertices = polygon.vertices.map {
                CSGVertex(pos: pose.apply($0.pos), normal: pose.applyDir($0.normal))
            }
            return CSGPolygon(vertices: vertices, plane: plane)
        }
    }
}
