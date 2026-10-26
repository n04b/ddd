//
//  FilletOverlay.swift
//  Режим скруглений без панели: ручки прямо на модели.
//
//  Тело в режиме становится полупрозрачным, поэтому задние и нижние рёбра
//  доступны без вращения камеры. На середине каждого ребра — ручка, в каждой
//  вершине — кольцо. Ручку тянут внутрь тела: значение растёт до засечки предела.
//  Рядом с активной ручкой — плашка значения: ввод числа, тип обработки и совет
//  для печати. Слой только рисует; события разбирает ViewportNSView.
//

import AppKit
import simd

/// Ручка на экране.
struct FilletHandle {
    let element: FilletElement
    let point: CGPoint
    /// Расстояние до глаза: при наложении выигрывает ближняя.
    let depth: Float
    /// Хотя бы одна грань элемента смотрит на камеру.
    let facing: Bool
    /// Смещение на экране на 1 мм значения — направление внутрь тела.
    let inward: CGVector
    /// Ручки рёбер короче 30 точек на экране скрыты: на мелких деталях они сливаются.
    let shown: Bool
}

struct FilletEdgeLine {
    let edge: Int
    let a: CGPoint
    let b: CGPoint
    let facing: Bool
}

/// Режим скруглений в экранных координатах вьюпорта.
struct FilletScene {
    let node: Node
    let rounding: BoxRounding
    let effective: [Double]
    let handles: [FilletHandle]
    let lines: [FilletEdgeLine]
    let bottom: Set<Int>

    static let minimumEdgeLength: CGFloat = 30

    @MainActor
    static func build(_ model: EditorModel, size: CGSize) -> FilletScene? {
        guard let node = model.activeFilletNode, size.width > 1, size.height > 1 else { return nil }
        let camera = model.camera
        let viewProj = camera.projectionMatrix(aspect: Float(size.width / size.height)) * camera.viewMatrix()
        let eye = camera.eye
        let pose = model.doc.worldPose(of: node.id)
        let h = node.size * 0.5
        let rounding = node.rounding ?? BoxRounding()

        func project(_ local: Vec3) -> (CGPoint, Float)? {
            let p = pose.apply(local)
            let clip = viewProj * SIMD4<Float>(Float(p.x), Float(p.y), Float(p.z), 1)
            guard clip.w > 1e-4 else { return nil }
            let point = CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * size.width,
                                y: CGFloat((clip.y / clip.w + 1) / 2) * size.height)
            let world = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            return (point, simd_length(world - eye))
        }

        func faceFacing(_ axis: Int, _ sign: Double) -> Bool {
            var normal = Vec3.zero
            normal[axis] = sign
            var center = Vec3.zero
            center[axis] = sign * h[axis]
            let n = pose.applyDir(normal)
            let c = pose.apply(center)
            let toEye = Vec3(Double(eye.x) - c.x, Double(eye.y) - c.y, Double(eye.z) - c.z)
            return n.dot(toEye) > 0
        }

        /// Экранный вектор 1 мм вдоль направления внутрь; если смотрим прямо
        /// вдоль него, тянем вниз по экрану.
        func inwardVector(from local: Vec3, base: CGPoint, direction: Vec3) -> CGVector {
            if let (tip, _) = project(local + direction) {
                let v = CGVector(dx: tip.x - base.x, dy: tip.y - base.y)
                if hypot(v.dx, v.dy) > 2 { return v }
            }
            let scale = size.height / CGFloat(2 * camera.distance * tan(camera.fovY / 2))
            return CGVector(dx: 0, dy: -scale)
        }

        var handles: [FilletHandle] = []
        var lines: [FilletEdgeLine] = []
        for e in 0..<12 {
            let l = BoxRounding.edgeLayout(e)
            var mid = Vec3.zero
            mid[l.b] = l.sb * h[l.b]
            mid[l.c] = l.sc * h[l.c]
            var a = mid
            var b = mid
            a[l.axis] = -h[l.axis]
            b[l.axis] = h[l.axis]
            guard let (pm, depth) = project(mid), let (pa, _) = project(a), let (pb, _) = project(b) else { continue }
            let facing = faceFacing(l.b, l.sb) || faceFacing(l.c, l.sc)
            var direction = Vec3.zero
            direction[l.b] = -l.sb / 2.0.squareRoot()
            direction[l.c] = -l.sc / 2.0.squareRoot()
            lines.append(FilletEdgeLine(edge: e, a: pa, b: pb, facing: facing))
            handles.append(FilletHandle(element: .edge(e), point: pm, depth: depth, facing: facing,
                                        inward: inwardVector(from: mid, base: pm, direction: direction),
                                        shown: hypot(pb.x - pa.x, pb.y - pa.y) >= minimumEdgeLength))
        }
        for v in 0..<8 {
            let s = BoxRounding.vertexSigns(v)
            let corner = Vec3(s.x * h.x, s.y * h.y, s.z * h.z)
            guard let (pc, depth) = project(corner) else { continue }
            let facing = faceFacing(0, s.x) || faceFacing(1, s.y) || faceFacing(2, s.z)
            handles.append(FilletHandle(element: .vertex(v), point: pc, depth: depth, facing: facing,
                                        inward: inwardVector(from: corner, base: pc, direction: -s / 3.0.squareRoot()),
                                        shown: true))
        }

        return FilletScene(node: node, rounding: rounding, effective: rounding.effectiveEdges(size: node.size),
                           handles: handles, lines: lines, bottom: Set(model.bottomEdges(of: node)))
    }

    /// Ручки под точкой, ближняя к камере первой.
    func handles(at point: CGPoint, radius: CGFloat = 9) -> [FilletHandle] {
        handles
            .filter { $0.shown && hypot($0.point.x - point.x, $0.point.y - point.y) <= radius }
            .sorted { a, b in
                // Вершины поверх рёбер: кольцо крупнее и стоит на конце ребра.
                if case .vertex = a.element, case .edge = b.element { return true }
                if case .edge = a.element, case .vertex = b.element { return false }
                return a.depth < b.depth
            }
    }

    func handle(_ element: FilletElement) -> FilletHandle? {
        handles.first { $0.element == element }
    }

    // MARK: Состояние элементов

    func isChamfer(_ e: Int) -> Bool { rounding.chamfers[e] }

    func isLimited(_ e: Int) -> Bool { effective[e] < rounding.edges[e] - 1e-6 }

    /// Скругление больше 1 мм у стола — нависание у самого стола.
    func needsPrintHint(_ e: Int) -> Bool {
        bottom.contains(e) && !rounding.chamfers[e] && rounding.edges[e] > 1
    }
}

// MARK: - Плашка значения

/// Что показывает плашка для выбранных ручек.
struct FilletBadge {
    let title: String
    let value: String
    let limit: String?
    let hint: String?
    let hintIsAction: Bool

    @MainActor
    static func make(_ model: EditorModel, _ scene: FilletScene) -> FilletBadge? {
        let selection = model.filletSelection
        guard !selection.isEmpty else { return nil }
        let rounding = scene.rounding
        let values = selection.map { EditorModel.filletValue($0, rounding) }
        let edges = selection.compactMap { if case .edge(let e) = $0 { return e } else { return nil } }
        let vertices = selection.compactMap { if case .vertex(let v) = $0 { return v } else { return nil } }

        let title: String
        if selection.count == 1 {
            switch selection[0] {
            case .edge(let e): title = BoxRounding.edgeName(e) + " edge"
            case .vertex(let v): title = BoxRounding.vertexName(v) + " corner"
            }
        } else {
            var parts: [String] = []
            if !edges.isEmpty { parts.append(edges.count == 1 ? "1 edge" : "\(edges.count) edges") }
            if !vertices.isEmpty { parts.append(vertices.count == 1 ? "1 corner" : "\(vertices.count) corners") }
            title = parts.joined(separator: " · ")
        }

        var prefix = ""
        if vertices.isEmpty {
            if edges.allSatisfy({ rounding.chamfers[$0] }) { prefix = "◢ " }
            else if edges.allSatisfy({ !rounding.chamfers[$0] }) { prefix = "R " }
        } else if edges.isEmpty {
            if vertices.allSatisfy({ rounding.cuts[$0] > 0 }) { prefix = "Cut " }
            else if vertices.allSatisfy({ rounding.cuts[$0] <= 0 }) { prefix = "Auto R " }
        }

        let lo = values.min() ?? 0
        let hi = values.max() ?? 0
        var value: String
        if hi - lo < 1e-6 {
            value = lo <= 0 && vertices.isEmpty ? "Sharp" : prefix + Fmt.number(lo) + " mm"
            let limited = edges.filter { scene.isLimited($0) }
            if !limited.isEmpty, edges.count == limited.count, let shown = limited.map({ scene.effective[$0] }).min() {
                value = prefix + "\(Fmt.number(lo)) → \(Fmt.number(shown)) mm"
            }
        } else {
            value = "Mixed · \(Fmt.number(lo))–\(Fmt.number(hi))"
        }

        var limit: String?
        if selection.count == 1 {
            limit = "≤ " + Fmt.number(model.filletLimit(selection[0], node: scene.node))
        }

        var hint: String?
        var action = false
        if edges.contains(where: { scene.needsPrintHint($0) }) {
            hint = "Bottom: replace with 45° chamfer"
            action = true
        } else if edges.contains(where: { scene.isLimited($0) }) {
            hint = "Limited by the box size"
        } else if values.contains(where: { $0 > 0 && $0 < 0.4 }) {
            hint = "Smaller than a 0.4 mm nozzle"
        }
        return FilletBadge(title: title, value: value, limit: limit, hint: hint, hintIsAction: action)
    }
}

// MARK: - Слой

final class FilletOverlayView: NSView {
    enum BadgePart {
        case value
        case menu
        case hint
    }

    weak var model: EditorModel?
    var hovered: FilletElement?
    var cursor: CGPoint?
    /// Ручка, которую сейчас тянут: рисуем её путь и засечку предела.
    var dragging: FilletElement?

    private(set) var valueRect: CGRect = .null
    private(set) var menuRect: CGRect = .null
    private(set) var hintRect: CGRect = .null

    private static let cyan = NSColor(red: 0.30, green: 0.84, blue: 0.98, alpha: 1)
    private static let yellow = NSColor(red: 1.00, green: 0.83, blue: 0.35, alpha: 1)
    private static let panel = NSColor(white: 0.08, alpha: 0.86)

    override var isFlipped: Bool { false }

    /// Слой не перехватывает мышь: всё разбирает вьюпорт под ним.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func badgePart(at point: CGPoint) -> BadgePart? {
        if menuRect.contains(point) { return .menu }
        if valueRect.contains(point) { return .value }
        if hintRect.contains(point) { return .hint }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        valueRect = .null
        menuRect = .null
        hintRect = .null
        guard let model, let scene = FilletScene.build(model, size: bounds.size),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = Set(model.filletSelection)

        for line in scene.lines {
            let e = line.edge
            let isSelected = selected.contains(.edge(e))
            let processed = scene.rounding.edges[e] > 0
            var color = processed ? NSColor(white: 1, alpha: 0.62) : NSColor(white: 1, alpha: 0.28)
            if scene.isLimited(e) || scene.needsPrintHint(e) { color = FilletOverlayView.yellow.withAlphaComponent(0.8) }
            if isSelected { color = FilletOverlayView.cyan }
            if !line.facing { color = color.withAlphaComponent(color.alphaComponent * 0.55) }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(isSelected ? 2.5 : (processed ? 1.5 : 1))
            context.setLineDash(phase: 0, lengths: line.facing ? [] : [4, 3])
            context.move(to: line.a)
            context.addLine(to: line.b)
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])

        if let element = dragging, let handle = scene.handle(element) {
            drawTrack(context, handle, model, scene)
        }

        // Сначала дальние, чтобы ближние ручки лежали сверху.
        for handle in scene.handles.sorted(by: { $0.depth > $1.depth }) where handle.shown {
            drawHandle(context, handle, scene, selected: selected.contains(handle.element),
                       hovered: hovered == handle.element)
        }

        if let active = model.filletSelection.last, let handle = scene.handle(active),
           let badge = FilletBadge.make(model, scene) {
            drawBadge(badge, at: handle.point)
        }

        if let hovered, dragging == nil, let cursor, let handle = scene.handle(hovered) {
            drawTooltip(for: handle, scene, at: cursor)
        }
    }

    // MARK: Рисование

    private func drawHandle(_ context: CGContext, _ handle: FilletHandle, _ scene: FilletScene,
                            selected: Bool, hovered: Bool) {
        let p = handle.point
        let alpha: CGFloat = handle.facing ? 1 : 0.55
        let accent = selected ? FilletOverlayView.cyan : NSColor.white
        if hovered {
            context.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        }
        switch handle.element {
        case .edge(let e):
            let processed = scene.rounding.edges[e] > 0
            let r: CGFloat = selected ? 5.5 : 4.5
            let warn = scene.isLimited(e) || scene.needsPrintHint(e)
            let path: CGPath
            if scene.isChamfer(e) && processed {
                let diamond = CGMutablePath()
                diamond.move(to: CGPoint(x: p.x, y: p.y + r + 1))
                diamond.addLine(to: CGPoint(x: p.x + r + 1, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y - r - 1))
                diamond.addLine(to: CGPoint(x: p.x - r - 1, y: p.y))
                diamond.closeSubpath()
                path = diamond
            } else {
                path = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
            }
            context.addPath(path)
            context.setFillColor((processed ? accent : NSColor(white: 0.1, alpha: 0.9)).withAlphaComponent(alpha).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor((warn ? FilletOverlayView.yellow : accent).withAlphaComponent(alpha).cgColor)
            context.setLineWidth(warn ? 2 : 1.5)
            context.strokePath()
        case .vertex(let v):
            let r: CGFloat = selected ? 7.5 : 6.5
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let cut = scene.rounding.cuts[v] > 0
            let path = cut ? CGPath(rect: rect.insetBy(dx: 1, dy: 1), transform: nil)
                           : CGPath(ellipseIn: rect, transform: nil)
            context.addPath(path)
            context.setStrokeColor(accent.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(selected ? 2.5 : 1.75)
            context.strokePath()
        }
    }

    /// Путь ручки внутрь тела: засечка на пределе, точка — текущее значение.
    private func drawTrack(_ context: CGContext, _ handle: FilletHandle, _ model: EditorModel, _ scene: FilletScene) {
        let limit = CGFloat(model.filletLimit(handle.element, node: scene.node))
        let value = CGFloat(EditorModel.filletValue(handle.element, scene.rounding))
        let v = handle.inward
        let end = CGPoint(x: handle.point.x + v.dx * limit, y: handle.point.y + v.dy * limit)
        let now = CGPoint(x: handle.point.x + v.dx * value, y: handle.point.y + v.dy * value)
        context.setStrokeColor(FilletOverlayView.cyan.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1.5)
        context.move(to: handle.point)
        context.addLine(to: end)
        context.strokePath()

        let length = max(hypot(v.dx, v.dy), 1e-6)
        let normal = CGVector(dx: -v.dy / length * 7, dy: v.dx / length * 7)
        context.setStrokeColor(FilletOverlayView.cyan.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: end.x - normal.dx, y: end.y - normal.dy))
        context.addLine(to: CGPoint(x: end.x + normal.dx, y: end.y + normal.dy))
        context.strokePath()

        context.setFillColor(FilletOverlayView.cyan.cgColor)
        context.fillEllipse(in: CGRect(x: now.x - 3.5, y: now.y - 3.5, width: 7, height: 7))
    }

    private func drawBadge(_ badge: FilletBadge, at anchor: CGPoint) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.55),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.95),
        ]
        let limitAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.38),
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: badge.hintIsAction ? .semibold : .regular),
            .foregroundColor: badge.hintIsAction ? FilletOverlayView.yellow : NSColor(white: 1, alpha: 0.5),
        ]
        let title = NSAttributedString(string: badge.title, attributes: titleAttrs)
        let value = NSAttributedString(string: badge.value, attributes: valueAttrs)
        let limit = badge.limit.map { NSAttributedString(string: $0, attributes: limitAttrs) }
        let arrow = NSAttributedString(string: "▾", attributes: valueAttrs)
        let hint = badge.hint.map { NSAttributedString(string: $0, attributes: hintAttrs) }

        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let valueWidth = value.size().width + (limit.map { $0.size().width + gap } ?? 0)
        let width = max(title.size().width, valueWidth + gap + arrow.size().width + 6, hint?.size().width ?? 0) + 2 * pad
        let height: CGFloat = 16 + 20 + (hint == nil ? 0 : 18) + pad

        var origin = CGPoint(x: anchor.x + 16, y: anchor.y - 16 - height)
        origin.x = min(max(origin.x, 6), bounds.width - width - 6)
        origin.y = min(max(origin.y, 6), bounds.height - height - 6)
        let box = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        FilletOverlayView.panel.setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        var y = box.maxY - pad / 2 - 14
        title.draw(at: CGPoint(x: box.minX + pad, y: y))
        y -= 20
        value.draw(at: CGPoint(x: box.minX + pad, y: y))
        var x = box.minX + pad + value.size().width + gap
        if let limit {
            limit.draw(at: CGPoint(x: x, y: y + 1.5))
            x += limit.size().width + gap
        }
        valueRect = CGRect(x: box.minX, y: y - 3, width: x - box.minX, height: 20)
        let arrowOrigin = CGPoint(x: box.maxX - pad - arrow.size().width, y: y)
        arrow.draw(at: arrowOrigin)
        menuRect = CGRect(x: arrowOrigin.x - 6, y: y - 3, width: box.maxX - arrowOrigin.x + 6, height: 20)
        if let hint {
            y -= 18
            hint.draw(at: CGPoint(x: box.minX + pad, y: y))
            if badge.hintIsAction {
                hintRect = CGRect(x: box.minX, y: y - 3, width: box.width, height: 18)
            }
        }
    }

    private func drawTooltip(for handle: FilletHandle, _ scene: FilletScene, at point: CGPoint) {
        let name: String
        let shortcuts: String
        switch handle.element {
        case .edge(let e):
            let value = scene.rounding.edges[e]
            let kind = value <= 0 ? "sharp" : (scene.isChamfer(e) ? "◢ \(Fmt.number(value))" : "R \(Fmt.number(value))")
            name = BoxRounding.edgeName(e) + " · " + kind
            shortcuts = "⌥ — all · double-click — parallel"
        case .vertex(let v):
            let cut = scene.rounding.cuts[v]
            name = BoxRounding.vertexName(v) + (cut > 0 ? " · cut \(Fmt.number(cut))" : " · auto")
            shortcuts = "⌥ — all corners"
        }
        let text = NSMutableAttributedString(string: name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
        ])
        text.append(NSAttributedString(string: shortcuts, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 1, alpha: 0.5),
        ]))
        let size = text.size()
        var origin = CGPoint(x: point.x + 14, y: point.y + 12)
        origin.x = min(origin.x, bounds.width - size.width - 16)
        origin.y = min(origin.y, bounds.height - size.height - 12)
        let box = CGRect(x: origin.x - 6, y: origin.y - 4, width: size.width + 12, height: size.height + 8)
        FilletOverlayView.panel.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin)
    }
}
