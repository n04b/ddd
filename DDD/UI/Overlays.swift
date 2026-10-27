//
//  Overlays.swift
//  Мелкие элементы поверх вьюпорта: куб навигации, статус, уведомления.
//

import SwiftUI
import AppKit
import simd

/// Стеклянный куб навигации: вращается вместе с камерой. Клик по грани, ребру
/// или углу поворачивает вид к этой стороне, перетаскивание — орбита,
/// правый клик — показать выделенное.
struct ViewCubeView: View {
    let model: EditorModel
    @State private var pointer: CGPoint?
    @State private var dragLast: CGPoint?

    static let size: CGFloat = 80

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        let cube = CubeProjection(angles: model.viewAngles, size: ViewCubeView.size)
        let hovered = dragLast == nil ? pointer.flatMap { cube.region(at: $0) } : nil

        Group {
            if Constants.flatViewCube {
                Canvas { context, _ in
                    cube.draw(in: &context, hovered: hovered)
                }
            } else {
                GlassCubeView(right: cube.right, up: cube.up, back: cube.back, hovered: hovered, extent: Float(CubeProjection.extent))
            }
        }
        .frame(width: ViewCubeView.size, height: ViewCubeView.size)
        .overlay { input(cube) }
    }

    /// Мышь ловит прозрачный слой: Metal-вид под ним событий не принимает.
    private func input(_ cube: CubeProjection) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Пока сдвиг меньше пары точек, это ещё клик.
                        let last = dragLast ?? value.startLocation
                        if dragLast == nil, hypot(value.translation.width, value.translation.height) < 3 { return }
                        // Куб маленький — крутим вдвое быстрее, чем во вьюпорте.
                        model.camera.orbit(dx: Float(value.location.x - last.x) * 2, dy: Float(value.location.y - last.y) * 2)
                        model.requestRedraw()
                        dragLast = value.location
                    }
                    .onEnded { value in
                        if dragLast == nil, let region = cube.region(at: value.startLocation) {
                            model.look(from: region)
                        }
                        dragLast = nil
                    }
            )
            .overlay(RightClickCatcher { model.frameSelection() })
            .help("Click a side to turn the view · drag to orbit · right-click to frame selection")
    }
}

/// Ловит только правый клик; остальные события проходят к SwiftUI под ним.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}

/// Грань куба: наружная нормаль и оси клеток (вправо, вверх). Ось Z — вверх, спереди — −Y.
private struct CubeFace {
    let normal: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>

    static let all = [
        CubeFace(normal: [0, -1, 0], right: [1, 0, 0], up: [0, 0, 1]),
        CubeFace(normal: [1, 0, 0], right: [0, 1, 0], up: [0, 0, 1]),
        CubeFace(normal: [0, 1, 0], right: [-1, 0, 0], up: [0, 0, 1]),
        CubeFace(normal: [-1, 0, 0], right: [0, -1, 0], up: [0, 0, 1]),
        CubeFace(normal: [0, 0, 1], right: [1, 0, 0], up: [0, 1, 0]),
        CubeFace(normal: [0, 0, -1], right: [1, 0, 0], up: [0, -1, 0]),
    ]

    /// Направление вида для клетки 3×3 на грани: центр — грань, края — рёбра, углы — вершины.
    func region(_ column: Float, _ row: Float) -> SIMD3<Float> {
        normal + right * column - up * row
    }
}

/// Ортографическая проекция куба ±1 в квадрат `size` по углам камеры:
/// попадание мышью и отрисовка серого куба.
private struct CubeProjection {
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let back: SIMD3<Float>
    let center: CGFloat
    let scale: CGFloat

    /// Половина кадра в единицах куба, общая с шейдером: скруглённый куб влезает при любом повороте.
    static let extent: CGFloat = 1.6

    /// Граница центральной клетки грани в локальных координатах (−1…1).
    private static let inner: CGFloat = 0.55

    init(angles: SIMD2<Float>, size: CGFloat) {
        var camera = OrbitCamera()
        camera.target = .zero
        camera.yaw = angles.x
        camera.pitch = angles.y
        let axes = camera.basis
        right = axes.right
        up = axes.up
        back = axes.back
        center = size / 2
        scale = size / 2 / CubeProjection.extent
    }

    private func point(_ p: SIMD3<Float>) -> CGPoint {
        CGPoint(x: center + CGFloat(simd_dot(p, right)) * scale,
                y: center - CGFloat(simd_dot(p, up)) * scale)
    }

    private func facing(_ face: CubeFace) -> CGFloat {
        CGFloat(simd_dot(face.normal, back))
    }

    /// Видимые грани; в ортографии они не перекрываются, порядок не важен.
    private var visibleFaces: [CubeFace] {
        CubeFace.all.filter { facing($0) > 0.05 }
    }

    /// Локальные координаты грани (−1…1, y вниз) → экран.
    private func transform(_ face: CubeFace) -> CGAffineTransform {
        let o = point(face.normal)
        let x = point(face.normal + face.right)
        let y = point(face.normal - face.up)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    private static func cell(_ value: CGFloat) -> Float {
        value < -inner ? -1 : (value > inner ? 1 : 0)
    }

    func region(at screen: CGPoint) -> SIMD3<Float>? {
        for face in visibleFaces {
            let local = screen.applying(transform(face).inverted())
            if abs(local.x) <= 1, abs(local.y) <= 1 {
                return face.region(Self.cell(local.x), Self.cell(local.y))
            }
        }
        return nil
    }

    private static func span(_ cell: Float) -> (CGFloat, CGFloat) {
        cell < 0 ? (-1, -inner) : (cell > 0 ? (inner, 1) : (-inner, inner))
    }

    /// Серый куб (Constants.flatViewCube): матовые грани и подсветка зоны под курсором.
    func draw(in context: inout GraphicsContext, hovered: SIMD3<Float>?) {
        for face in visibleFaces {
            let t = transform(face)
            let outline = Path(CGRect(x: -1, y: -1, width: 2, height: 2)).applying(t)
            context.fill(outline, with: .color(Color.black.opacity(0.35)))
            // Свет привязан к миру: верх светлее, перед чуть светлее боков — так куб читается без подписей.
            let light = 0.08 + 0.06 * Double(face.normal.z) - 0.02 * Double(face.normal.y)
            context.fill(outline, with: .color(Color.white.opacity(light)))

            if let hovered {
                for row: Float in [-1, 0, 1] {
                    for column: Float in [-1, 0, 1] where face.region(column, row) == hovered {
                        let (x0, x1) = Self.span(column)
                        let (y0, y1) = Self.span(row)
                        let cell = Path(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)).applying(t)
                        context.fill(cell, with: .color(Theme.cyan.opacity(0.45)))
                    }
                }
            }
            context.stroke(outline, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
        }
    }
}

struct StatusView: View {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.isComputing {
                ProgressView()
                    .controlSize(.mini)
                Text("computing")
            } else if model.output.isDraft {
                Text("draft")
            }
            Text("\(model.partTriangles) tris · \(Int(model.output.milliseconds.rounded())) ms")
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.tertiary)
    }
}

struct ToastView: View {
    let model: EditorModel
    let toast: Toast

    init(model: EditorModel, toast: Toast) {
        self.model = model
        self.toast = toast
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(Theme.label(12))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            if toast.canUndo {
                Button("Undo") {
                    model.undo()
                    model.toast = nil
                }
                .buttonStyle(.plain)
                .font(Theme.label(12, .semibold))
                .foregroundStyle(Theme.cyan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        .glass(radius: 18)
    }
}
