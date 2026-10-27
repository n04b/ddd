//
//  OrbitCamera.swift
//  Орбитальная камера, ось Z вверх (как у принтера).
//

import Foundation
import simd

struct OrbitCamera: Equatable {
    var target = SIMD3<Float>(0, 0, 10)
    var distance: Float = 240
    var yaw: Float = -Float.pi / 4
    var pitch: Float = 0.6
    let fovY: Float = 35 * Float.pi / 180

    static let maxPitch: Float = 1.553

    var eye: SIMD3<Float> {
        let c = cos(pitch)
        return target + distance * SIMD3<Float>(c * cos(yaw), c * sin(yaw), sin(pitch))
    }

    /// Правый, верхний и «назад» векторы камеры.
    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, back: SIMD3<Float>) {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), back))
        let up = simd_cross(back, right)
        return (right, up, back)
    }

    func viewMatrix() -> simd_float4x4 {
        let axes = basis
        let x = axes.right
        let y = axes.up
        let z = axes.back
        let e = eye
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, e), -simd_dot(y, e), -simd_dot(z, e), 1)
        ))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let near = max(distance * 0.01, 0.1)
        let far = distance * 50 + 2000
        let ys = 1 / tan(fovY / 2)
        let xs = ys / max(aspect, 0.01)
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    /// Луч из глаза через точку экрана в нормализованных координатах (-1…1).
    func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let inverse = (projectionMatrix(aspect: aspect) * viewMatrix()).inverse
        let far = inverse * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        let point = SIMD3<Float>(far.x, far.y, far.z) / far.w
        let origin = eye
        return (origin, simd_normalize(point - origin))
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -OrbitCamera.maxPitch), OrbitCamera.maxPitch)
    }

    /// Сдвиг в точках экрана: сцена следует за курсором.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let scale = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        let axes = basis
        target += (-axes.right * dx + axes.up * dy) * scale
    }

    mutating func zoom(factor: Float) {
        distance = min(max(distance * factor, 2), 20000)
    }

    mutating func frame(_ box: AABB) {
        let center = box.center
        let radius = max(Float(box.size.length / 2), 5)
        target = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
        distance = radius / sin(fovY / 2) * 1.15
    }
}
