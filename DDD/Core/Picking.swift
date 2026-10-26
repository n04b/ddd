//
//  Picking.swift
//  Выбор объекта лучом: аналитическое пересечение с исходными примитивами.
//

import Foundation

nonisolated struct Ray: Sendable {
    var origin: Vec3
    var dir: Vec3
}

nonisolated enum Picking {
    /// Ближайший видимый примитив под лучом: путь id от корня и расстояние.
    static func pick(_ document: SceneDocument, ray: Ray) -> (path: [UUID], t: Double)? {
        var best: (path: [UUID], t: Double)?

        func walk(_ nodes: [Node], parent: Pose, path: [UUID]) {
            for node in nodes where node.visible {
                let pose = parent * node.pose
                let nodePath = path + [node.id]
                if node.kind == .group {
                    walk(node.children, parent: pose, path: nodePath)
                    continue
                }
                let inverse = pose.inverse
                let local = Ray(origin: inverse.apply(ray.origin), dir: inverse.applyDir(ray.dir))
                if let t = intersect(node, local), t < (best?.t ?? Double.infinity) {
                    best = (nodePath, t)
                }
            }
        }

        walk(document.nodes, parent: .identity, path: [])
        return best
    }

    static func intersect(_ node: Node, _ ray: Ray) -> Double? {
        switch node.kind {
        case .box: return box(half: node.size * 0.5, ray)
        case .sphere: return sphere(radius: node.size.x / 2, ray)
        case .cylinder: return cylinder(radius: node.size.x / 2, halfHeight: node.size.z / 2, ray)
        case .group: return nil
        }
    }

    static func box(half: Vec3, _ ray: Ray) -> Double? {
        var tmin = -Double.infinity
        var tmax = Double.infinity
        for axis in 0..<3 {
            let o = ray.origin[axis]
            let d = ray.dir[axis]
            let h = half[axis]
            if abs(d) < 1e-12 {
                if o < -h || o > h { return nil }
            } else {
                let t1 = (-h - o) / d
                let t2 = (h - o) / d
                tmin = max(tmin, min(t1, t2))
                tmax = min(tmax, max(t1, t2))
            }
        }
        guard tmax >= max(tmin, 0) else { return nil }
        return tmin >= 0 ? tmin : tmax
    }

    static func sphere(radius: Double, _ ray: Ray) -> Double? {
        let b = ray.origin.dot(ray.dir)
        let c = ray.origin.dot(ray.origin) - radius * radius
        let disc = b * b - c
        guard disc >= 0 else { return nil }
        let s = disc.squareRoot()
        let t0 = -b - s
        if t0 >= 0 { return t0 }
        let t1 = -b + s
        return t1 >= 0 ? t1 : nil
    }

    static func cylinder(radius: Double, halfHeight: Double, _ ray: Ray) -> Double? {
        let o = ray.origin
        let d = ray.dir
        var best = Double.infinity

        let a = d.x * d.x + d.y * d.y
        if a > 1e-12 {
            let b = o.x * d.x + o.y * d.y
            let c = o.x * o.x + o.y * o.y - radius * radius
            let disc = b * b - a * c
            if disc >= 0 {
                let s = disc.squareRoot()
                for t in [(-b - s) / a, (-b + s) / a] where t >= 0 && t < best {
                    if abs(o.z + t * d.z) <= halfHeight { best = t }
                }
            }
        }
        if abs(d.z) > 1e-12 {
            for z in [halfHeight, -halfHeight] {
                let t = (z - o.z) / d.z
                guard t >= 0, t < best else { continue }
                let x = o.x + t * d.x
                let y = o.y + t * d.y
                if x * x + y * y <= radius * radius { best = t }
            }
        }
        return best.isFinite ? best : nil
    }
}
