//
//  ReferenceOverlay.swift
//  Разметка референсов поверх вьюпорта: рамка выделенной картинки с её размером,
//  точки с метками, линейка калибровки и подсказка с координатами точки.
//  Точки рисуются всегда поверх модели — по ним ориентируются при построении.
//  Слой только рисует; события разбирает ViewportNSView.
//

import AppKit
import simd

/// Точка разметки на конкретной картинке.
struct MarkerRef: Equatable {
    let reference: UUID
    let marker: UUID
}

final class ReferenceOverlayView: NSView {
    weak var model: EditorModel?
    /// Курсор: за ним тянется линейка калибровки и подсказка точки.
    var cursor: CGPoint?
    var hovered: MarkerRef?
    /// Открыто поле ввода длины: подпись на линейке не нужна.
    var editingLength = false

    static let cyan = NSColor(red: 0.30, green: 0.84, blue: 0.98, alpha: 1)
    static let ruler = NSColor(red: 1.00, green: 0.83, blue: 0.35, alpha: 1)
    private static let panel = NSColor(white: 0.08, alpha: 0.86)
    /// Радиус, в котором точка ловит курсор.
    static let hitRadius: CGFloat = 8

    override var isFlipped: Bool { false }

    /// Слой не перехватывает мышь: всё разбирает вьюпорт под ним.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, !model.doc.references.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let view = ViewportGeometry(camera: model.camera, size: bounds.size)
        let visible = model.doc.references.filter(\.visible)
        let active = visible.first { $0.id == model.selectedReference }

        if let active {
            drawFrame(context, active, view)
            if let distance = model.selectedMarkerDistance {
                drawMeasure(context, active, distance.from, distance.to, view)
            }
        }
        // Сначала точки остальных картинок, сверху — точки выделенной.
        for reference in visible where reference.id != active?.id {
            drawMarkers(context, reference, view, active: false, selected: [])
        }
        if let active {
            drawMarkers(context, active, view, active: true, selected: Set(model.markerSelection))
            if model.referenceTool == .calibrate {
                drawCalibration(context, active, model.calibrationPoints, view)
            }
        }
        if let hovered, let cursor, model.referenceTool != .calibrate,
           let reference = visible.first(where: { $0.id == hovered.reference }),
           let marker = reference.markers.first(where: { $0.id == hovered.marker }) {
            drawTooltip(reference, marker, at: cursor)
        }
    }

    // MARK: Попадание

    /// Точка разметки под курсором: ближайшая из видимых картинок.
    static func marker(at point: CGPoint, in model: EditorModel, size: CGSize) -> MarkerRef? {
        let view = ViewportGeometry(camera: model.camera, size: size)
        var best: (ref: MarkerRef, distance: CGFloat)?
        for reference in model.doc.references where reference.visible {
            for marker in reference.markers {
                guard let p = view.project(reference.world(marker.point)) else { continue }
                var d = hypot(p.x - point.x, p.y - point.y)
                // При равенстве побеждают точки выделенной картинки.
                if reference.id == model.selectedReference { d -= 0.5 }
                if d <= hitRadius, d < (best?.distance ?? .infinity) {
                    best = (MarkerRef(reference: reference.id, marker: marker.id), d)
                }
            }
        }
        return best?.ref
    }

    // MARK: Рисование

    /// Рамка картинки и подпись с размером у её нижнего левого угла.
    private func drawFrame(_ context: CGContext, _ reference: ReferenceImage, _ view: ViewportGeometry) {
        let corners = reference.corners
        context.setStrokeColor(ReferenceOverlayView.cyan.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: reference.locked ? [5, 4] : [])
        for i in 0..<4 {
            guard let (a, b) = view.segment(corners[i], corners[(i + 1) % 4]) else { continue }
            context.move(to: a)
            context.addLine(to: b)
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        guard let anchor = view.project(corners[3]) else { return }
        var caption = "\(Fmt.number(reference.width)) × \(Fmt.number(reference.height)) mm · \(Fmt.number(reference.dpi)) dpi"
        if reference.locked { caption += " · locked" }
        drawPill(caption, at: CGPoint(x: anchor.x + 4, y: anchor.y - 22), color: NSColor(white: 1, alpha: 0.85),
                 font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium))
    }

    private func drawMarkers(_ context: CGContext, _ reference: ReferenceImage, _ view: ViewportGeometry,
                             active: Bool, selected: Set<UUID>) {
        for marker in reference.markers {
            guard let p = view.project(reference.world(marker.point)),
                  bounds.insetBy(dx: -40, dy: -40).contains(p) else { continue }
            let isHovered = hovered == MarkerRef(reference: reference.id, marker: marker.id)
            drawMarker(context, at: p, label: marker.label, active: active,
                       selected: selected.contains(marker.id), hovered: isHovered)
        }
    }

    /// Кольцо с точкой в центре: пиксель под меткой остаётся виден.
    private func drawMarker(_ context: CGContext, at p: CGPoint, label: String,
                            active: Bool, selected: Bool, hovered: Bool) {
        let r: CGFloat = active ? 5 : 4
        let ring = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let color = selected ? ReferenceOverlayView.cyan : NSColor(white: 1, alpha: active ? 0.95 : 0.7)

        context.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
        context.setLineWidth(3.5)
        context.strokeEllipse(in: ring)
        if selected || hovered {
            context.setFillColor(color.withAlphaComponent(0.28).cgColor)
            context.fillEllipse(in: ring)
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: ring)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))

        drawPill(label, at: CGPoint(x: p.x + r + 3, y: p.y + r - 3), color: color,
                 font: NSFont.systemFont(ofSize: active ? 10.5 : 9.5, weight: .semibold))
    }

    /// Пунктир между двумя выделенными точками и расстояние посередине.
    private func drawMeasure(_ context: CGContext, _ reference: ReferenceImage, _ a: ReferenceMarker,
                             _ b: ReferenceMarker, _ view: ViewportGeometry) {
        guard let (pa, pb) = view.segment(reference.world(a.point), reference.world(b.point)) else { return }
        context.setStrokeColor(ReferenceOverlayView.cyan.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1.25)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.move(to: pa)
        context.addLine(to: pb)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let length = a.point.distance(to: b.point) * reference.mmPerPixel
        let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
        drawPill("\(Fmt.number(length)) mm", at: CGPoint(x: mid.x + 6, y: mid.y + 6), color: ReferenceOverlayView.cyan,
                 font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold))
    }

    /// Линейка: поставленные концы, резинка к курсору и длина в текущем масштабе.
    private func drawCalibration(_ context: CGContext, _ reference: ReferenceImage, _ points: [Point2],
                                 _ view: ViewportGeometry) {
        guard let model else { return }
        var ends = points
        if ends.count == 1, let cursor {
            // Резинка прилипает к точке разметки под курсором — так калибруют по точкам.
            if let hovered, hovered.reference == reference.id,
               let marker = reference.markers.first(where: { $0.id == hovered.marker }) {
                ends.append(marker.point)
            } else if let hit = reference.planeHit(view.ray(cursor)) {
                ends.append(hit.pixel)
            }
        }
        let screen = ends.compactMap { view.project(reference.world($0)) }
        let color = ReferenceOverlayView.ruler
        if screen.count == 2, let (a, b) = view.segment(reference.world(ends[0]), reference.world(ends[1])) {
            context.setStrokeColor(NSColor(white: 0, alpha: 0.5).cgColor)
            context.setLineWidth(3.5)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.5)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
            // Засечки поперёк линейки на концах.
            let length = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
            let normal = CGVector(dx: -(b.y - a.y) / length * 6, dy: (b.x - a.x) / length * 6)
            for p in [a, b] {
                context.move(to: CGPoint(x: p.x - normal.dx, y: p.y - normal.dy))
                context.addLine(to: CGPoint(x: p.x + normal.dx, y: p.y + normal.dy))
            }
            context.strokePath()
            if !(editingLength && model.calibrationPoints.count == 2) {
                let millimeters = ends[0].distance(to: ends[1]) * reference.mmPerPixel
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                drawPill("\(Fmt.number(millimeters)) mm now", at: CGPoint(x: mid.x + 8, y: mid.y + 8), color: color,
                         font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold))
            }
        }
        for p in screen.prefix(points.count) {
            context.setFillColor(NSColor(white: 0, alpha: 0.6).cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
    }

    /// Метка и мировые координаты точки под курсором.
    private func drawTooltip(_ reference: ReferenceImage, _ marker: ReferenceMarker, at point: CGPoint) {
        let world = reference.world(marker.point)
        let text = NSMutableAttributedString(string: marker.label + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ])
        text.append(NSAttributedString(string: "X \(Fmt.number(world.x))  Y \(Fmt.number(world.y))  Z \(Fmt.number(world.z)) mm",
                                       attributes: [
                                           .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                           .foregroundColor: NSColor(white: 1, alpha: 0.6),
                                       ]))
        let size = text.size()
        var origin = CGPoint(x: point.x + 14, y: point.y + 12)
        origin.x = min(origin.x, bounds.width - size.width - 16)
        origin.y = min(origin.y, bounds.height - size.height - 12)
        let box = CGRect(x: origin.x - 6, y: origin.y - 4, width: size.width + 12, height: size.height + 8)
        ReferenceOverlayView.panel.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin)
    }

    /// Подпись на тёмной плашке; не вылезает за край вьюпорта.
    private func drawPill(_ string: String, at origin: CGPoint, color: NSColor, font: NSFont) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        var x = origin.x
        var y = origin.y
        x = min(max(x, 4), bounds.width - size.width - 12)
        y = min(max(y, 4), bounds.height - size.height - 6)
        let box = CGRect(x: x, y: y, width: size.width + 8, height: size.height + 2)
        NSColor(white: 0.06, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 1))
    }
}
