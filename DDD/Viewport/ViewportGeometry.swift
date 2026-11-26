//
//  ViewportGeometry.swift
//  Экран вьюпорта ↔ мир: луч через точку экрана и проекция точки на экран.
//  Координаты экрана — точки AppKit, начало внизу слева.
//

import Foundation
import CoreGraphics
import simd

struct ViewportGeometry {
    let camera: OrbitCamera
    let size: CGSize
    let viewProj: simd_float4x4

    init(camera: OrbitCamera, size: CGSize) {
        self.camera = camera
        self.size = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        viewProj = camera.projectionMatrix(aspect: Float(self.size.width / self.size.height)) * camera.viewMatrix()
    }

    func ray(_ point: CGPoint) -> Ray {
        let ndc = SIMD2<Float>(Float(point.x / size.width * 2 - 1), Float(point.y / size.height * 2 - 1))
        let ray = camera.ray(ndc: ndc, aspect: Float(size.width / size.height))
        return Ray(origin: Vec3(ray.origin), dir: Vec3(ray.direction))
    }

    /// nil — точка за камерой.
    func project(_ point: Vec3) -> CGPoint? {
        let c = clip(point)
        guard c.w > 1e-4 else { return nil }
        return screen(c)
    }

    /// Отрезок на экране; часть за камерой отрезается.
    func segment(_ a: Vec3, _ b: Vec3) -> (CGPoint, CGPoint)? {
        var ca = clip(a)
        var cb = clip(b)
        let near: Float = 1e-3
        if ca.w < near && cb.w < near { return nil }
        if ca.w < near {
            ca = ca + (cb - ca) * ((near - ca.w) / (cb.w - ca.w))
        } else if cb.w < near {
            cb = cb + (ca - cb) * ((near - cb.w) / (ca.w - cb.w))
        }
        return (screen(ca), screen(cb))
    }

    /// Сколько точек экрана занимает миллиметр рядом с точкой `point`.
    func pointsPerMillimeter(at point: Vec3) -> CGFloat {
        let depth = max(simd_length(SIMD3<Float>(point) - camera.eye), 1e-3)
        return size.height / CGFloat(2 * depth * tan(camera.fovY / 2))
    }

    private func clip(_ p: Vec3) -> SIMD4<Float> {
        viewProj * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
    }

    private func screen(_ c: SIMD4<Float>) -> CGPoint {
        CGPoint(x: CGFloat((c.x / c.w + 1) / 2) * size.width,
                y: CGFloat((c.y / c.w + 1) / 2) * size.height)
    }
}

extension Vec3 {
    init(_ v: SIMD3<Float>) {
        self.init(Double(v.x), Double(v.y), Double(v.z))
    }
}

extension SIMD3 where Scalar == Float {
    init(_ v: Vec3) {
        self.init(Float(v.x), Float(v.y), Float(v.z))
    }
}
