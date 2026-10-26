//
//  ViewportView.swift
//  MTKView с управлением мышью, трекпадом и клавиатурой.
//
//  Мышь:  клик — выбрать, двойной клик — объект внутри группы, ⌘-клик — добавить к выделению,
//         тянуть объект — двигать по столу (⇧ — по высоте, ⌥ — без шага 1 мм),
//         тянуть пустое место — вращать, ⇧ + тянуть пустое — панорама,
//         правая кнопка — вращать, средняя — панорама, колесо — масштаб.
//  Трекпад: два пальца — вращать, ⇧ + два пальца — панорама, щипок — масштаб.
//

import SwiftUI
import MetalKit
import AppKit
import simd

struct ViewportView: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> ViewportNSView {
        ViewportNSView(model: model)
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        // Чтение подписывает представление на изменения выделения и результата ядра.
        _ = model.selection
        _ = model.output.generation
        view.needsDisplay = true
    }
}

final class ViewportNSView: MTKView {
    private enum DragMode {
        case none
        case orbit
        case pan
        case deselectOrOrbit
        case move(anchor: Vec3, vertical: Bool)
    }

    private let model: EditorModel
    private var renderer: Renderer?
    private var dragMode: DragMode = .none
    private var mouseDownPoint: NSPoint = .zero
    private var dragged = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        clearDepth = 1
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.isOpaque = false
        renderer = Renderer(view: self, model: model)
        delegate = renderer
        model.redrawHandler = { [weak self] in
            self?.needsDisplay = true
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        window?.makeFirstResponder(self)
    }

    // MARK: Мышь

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        dragged = false
        let flags = event.modifierFlags

        guard let hit = model.pick(worldRay(point)) else {
            dragMode = flags.contains(.shift) ? .pan : .deselectOrOrbit
            return
        }
        let target = model.selectionTarget(for: hit.path, deep: event.clickCount >= 2)
        if flags.contains(.command) {
            model.toggleSelection(target)
            dragMode = .none
            return
        }
        if !model.selection.contains(target) {
            model.select(target)
        }
        model.beginMove()
        dragMode = .move(anchor: hit.point, vertical: flags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !dragged {
            let distance = hypot(Double(point.x - mouseDownPoint.x), Double(point.y - mouseDownPoint.y))
            guard distance >= 3 else { return }
            dragged = true
        }
        switch dragMode {
        case let .move(anchor, vertical):
            if let delta = moveDelta(to: point, anchor: anchor, vertical: vertical) {
                model.updateMove(worldDelta: delta, snap: !event.modifierFlags.contains(.option))
            }
        case .orbit, .deselectOrOrbit:
            dragMode = .orbit
            model.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
            model.requestRedraw()
        case .pan:
            model.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
            model.requestRedraw()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .move:
            model.endMove()
        case .deselectOrOrbit:
            if !dragged { model.select(nil) }
        default:
            break
        }
        dragMode = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        model.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        model.requestRedraw()
    }

    override func otherMouseDragged(with event: NSEvent) {
        model.camera.pan(dx: Float(event.deltaX), dy: Float(event.deltaY), viewHeight: Float(bounds.height))
        model.requestRedraw()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Знак приводим к «натуральной» прокрутке: сцена следует за пальцами.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let dx = Float(event.scrollingDeltaX * sign)
            let dy = Float(event.scrollingDeltaY * sign)
            if event.modifierFlags.contains(.shift) {
                model.camera.pan(dx: dx, dy: dy, viewHeight: Float(bounds.height))
            } else if event.modifierFlags.contains(.command) {
                model.camera.zoom(factor: pow(1.01, dy))
            } else {
                model.camera.orbit(dx: dx, dy: dy)
            }
        } else {
            model.camera.zoom(factor: pow(0.88, Float(event.scrollingDeltaY)))
        }
        model.requestRedraw()
    }

    override func magnify(with event: NSEvent) {
        let m = max(Float(event.magnification), -0.9)
        model.camera.zoom(factor: 1 / (1 + m))
        model.requestRedraw()
    }

    // MARK: Клавиатура

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: Double = flags.contains(.shift) ? 10 : (flags.contains(.option) ? 0.1 : 1)

        // Cmd + ↑/↓ — по вертикали (ось Z).
        if flags.contains(.command) {
            switch event.keyCode {
            case 126: model.nudge(Vec3(0, 0, step)); return
            case 125: model.nudge(Vec3(0, 0, -step)); return
            default: break
            }
        }

        switch event.keyCode {
        case 123: model.nudge(Vec3(-step, 0, 0)); return
        case 124: model.nudge(Vec3(step, 0, 0)); return
        case 125: model.nudge(Vec3(0, -step, 0)); return
        case 126: model.nudge(Vec3(0, step, 0)); return
        case 116: model.nudge(Vec3(0, 0, step)); return
        case 121: model.nudge(Vec3(0, 0, -step)); return
        case 51, 117: model.deleteSelection(); return
        case 53: model.select(nil); return
        default: break
        }

        if flags.contains(.command) || flags.contains(.control) {
            super.keyDown(with: event)
            return
        }

        // Коды клавиш, а не символы: работает и в русской раскладке.
        switch event.keyCode {
        case 11: model.add(.box)          // B
        case 1: model.add(.sphere)        // S
        case 8: model.add(.cylinder)      // C
        case 4: model.toggleHole()        // H
        case 5: model.groupSelection()    // G
        case 3: model.frameSelection()    // F
        case 18: model.setView(.iso)      // 1
        case 19: model.setView(.top)      // 2
        case 20: model.setView(.front)    // 3
        case 21: model.setView(.right)    // 4
        default: super.keyDown(with: event)
        }
    }

    // MARK: Геометрия экрана

    private func worldRay(_ point: NSPoint) -> Ray {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let ndc = SIMD2<Float>(Float(point.x / width * 2 - 1), Float(point.y / height * 2 - 1))
        let ray = model.camera.ray(ndc: ndc, aspect: Float(width / height))
        return Ray(origin: Vec3(Double(ray.origin.x), Double(ray.origin.y), Double(ray.origin.z)),
                   dir: Vec3(Double(ray.direction.x), Double(ray.direction.y), Double(ray.direction.z)))
    }

    private func moveDelta(to point: NSPoint, anchor: Vec3, vertical: Bool) -> Vec3? {
        let ray = worldRay(point)
        if vertical {
            let eye = model.camera.eye
            var normal = Vec3(Double(eye.x) - anchor.x, Double(eye.y) - anchor.y, 0)
            if normal.length < 1e-6 { normal = Vec3(0, -1, 0) }
            guard let hit = ViewportNSView.intersect(ray, planePoint: anchor, normal: normal.normalized) else { return nil }
            return Vec3(0, 0, hit.z - anchor.z)
        }
        guard let hit = ViewportNSView.intersect(ray, planePoint: anchor, normal: Vec3(0, 0, 1)) else { return nil }
        return Vec3(hit.x - anchor.x, hit.y - anchor.y, 0)
    }

    private static func intersect(_ ray: Ray, planePoint: Vec3, normal: Vec3) -> Vec3? {
        let denom = ray.dir.dot(normal)
        guard abs(denom) > 1e-9 else { return nil }
        let t = (planePoint - ray.origin).dot(normal) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.dir * t
    }
}
