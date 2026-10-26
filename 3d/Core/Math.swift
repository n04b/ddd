//
//  Math.swift
//  Математика ядра на Double без simd: ядро не зависит от Apple-фреймворков
//  и в будущем соберётся под Windows и Linux.
//

import Foundation

nonisolated struct Vec3: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)

    subscript(axis: Int) -> Double {
        get {
            switch axis {
            case 0: return x
            case 1: return y
            default: return z
            }
        }
        set {
            switch axis {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }

    func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    var length: Double { (x * x + y * y + z * z).squareRoot() }

    var normalized: Vec3 {
        let l = length
        return l > 1e-12 ? self / l : Vec3(0, 0, 1)
    }

    func lerp(_ b: Vec3, _ t: Double) -> Vec3 { self + (b - self) * t }

    /// Убирает шум после тригонометрии. Микрон точности печати не мешает.
    var cleaned: Vec3 { Vec3(Vec3.clean(x), Vec3.clean(y), Vec3.clean(z)) }

    static func clean(_ v: Double) -> Double {
        let r = (v * 1e6).rounded() / 1e6
        return r == 0 ? 0 : r
    }
}

/// Матрица 3×3 по строкам.
nonisolated struct Mat3: Equatable, Sendable {
    var r0: Vec3
    var r1: Vec3
    var r2: Vec3

    static let identity = Mat3(r0: Vec3(1, 0, 0), r1: Vec3(0, 1, 0), r2: Vec3(0, 0, 1))

    var transposed: Mat3 {
        Mat3(r0: Vec3(r0.x, r1.x, r2.x),
             r1: Vec3(r0.y, r1.y, r2.y),
             r2: Vec3(r0.z, r1.z, r2.z))
    }

    static func * (m: Mat3, v: Vec3) -> Vec3 {
        Vec3(m.r0.dot(v), m.r1.dot(v), m.r2.dot(v))
    }

    static func * (a: Mat3, b: Mat3) -> Mat3 {
        let c = b.transposed
        return Mat3(r0: Vec3(a.r0.dot(c.r0), a.r0.dot(c.r1), a.r0.dot(c.r2)),
                    r1: Vec3(a.r1.dot(c.r0), a.r1.dot(c.r1), a.r1.dot(c.r2)),
                    r2: Vec3(a.r2.dot(c.r0), a.r2.dot(c.r1), a.r2.dot(c.r2)))
    }

    /// Поворот на углы Эйлера в градусах: сначала X, потом Y, потом Z (R = Rz·Ry·Rx).
    static func rotation(degrees e: Vec3) -> Mat3 {
        let a = e.x * .pi / 180
        let b = e.y * .pi / 180
        let c = e.z * .pi / 180
        let rx = Mat3(r0: Vec3(1, 0, 0),
                      r1: Vec3(0, cos(a), -sin(a)),
                      r2: Vec3(0, sin(a), cos(a)))
        let ry = Mat3(r0: Vec3(cos(b), 0, sin(b)),
                      r1: Vec3(0, 1, 0),
                      r2: Vec3(-sin(b), 0, cos(b)))
        let rz = Mat3(r0: Vec3(cos(c), -sin(c), 0),
                      r1: Vec3(sin(c), cos(c), 0),
                      r2: Vec3(0, 0, 1))
        return rz * (ry * rx)
    }

    /// Обратное к rotation(degrees:).
    var eulerDegrees: Vec3 {
        let sb = Swift.max(-1.0, Swift.min(1.0, -r2.x))
        let b = asin(sb)
        let a: Double
        let c: Double
        if abs(sb) < 0.999999 {
            a = atan2(r2.y, r2.z)
            c = atan2(r1.x, r0.x)
        } else {
            a = atan2(-r1.z, r1.y)
            c = 0
        }
        return Vec3(a * 180 / .pi, b * 180 / .pi, c * 180 / .pi)
    }
}

/// Жёсткое преобразование: поворот + перенос.
nonisolated struct Pose: Sendable {
    var rotation: Mat3
    var translation: Vec3

    static let identity = Pose(rotation: .identity, translation: .zero)

    init(rotation: Mat3, translation: Vec3) {
        self.rotation = rotation
        self.translation = translation
    }

    init(position: Vec3, rotationDegrees: Vec3) {
        rotation = rotationDegrees == .zero ? .identity : Mat3.rotation(degrees: rotationDegrees)
        translation = position
    }

    var isIdentity: Bool { rotation == .identity && translation == .zero }

    func apply(_ p: Vec3) -> Vec3 { rotation * p + translation }

    func applyDir(_ v: Vec3) -> Vec3 { rotation * v }

    var inverse: Pose {
        let rt = rotation.transposed
        return Pose(rotation: rt, translation: -(rt * translation))
    }

    /// a * b: сначала b, потом a.
    static func * (a: Pose, b: Pose) -> Pose {
        Pose(rotation: a.rotation * b.rotation,
             translation: a.rotation * b.translation + a.translation)
    }
}

nonisolated struct AABB: Sendable, Equatable {
    var lo: Vec3
    var hi: Vec3

    static let empty = AABB(lo: Vec3(Double.infinity, Double.infinity, Double.infinity),
                            hi: Vec3(-Double.infinity, -Double.infinity, -Double.infinity))

    var isEmpty: Bool { lo.x > hi.x || lo.y > hi.y || lo.z > hi.z }
    var size: Vec3 { isEmpty ? .zero : hi - lo }
    var center: Vec3 { isEmpty ? .zero : (lo + hi) * 0.5 }

    mutating func include(_ p: Vec3) {
        lo = Vec3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
        hi = Vec3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
    }

    mutating func formUnion(_ other: AABB) {
        guard !other.isEmpty else { return }
        include(other.lo)
        include(other.hi)
    }

    /// Габариты после поворота и переноса (по восьми углам).
    func transformed(by pose: Pose) -> AABB {
        guard !isEmpty else { return self }
        if pose.isIdentity { return self }
        var result = AABB.empty
        for corner in 0..<8 {
            let p = Vec3(corner & 1 == 0 ? lo.x : hi.x,
                         corner & 2 == 0 ? lo.y : hi.y,
                         corner & 4 == 0 ? lo.z : hi.z)
            result.include(pose.apply(p))
        }
        return result
    }

    func intersects(_ other: AABB, margin: Double = 1e-6) -> Bool {
        guard !isEmpty, !other.isEmpty else { return false }
        return lo.x <= other.hi.x + margin && hi.x >= other.lo.x - margin
            && lo.y <= other.hi.y + margin && hi.y >= other.lo.y - margin
            && lo.z <= other.hi.z + margin && hi.z >= other.lo.z - margin
    }
}
