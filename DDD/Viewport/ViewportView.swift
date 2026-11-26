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
//  Режим скруглений (двойной клик по выделенному блоку): клик по ручке — выбрать,
//  ⇧ — добавить, двойной клик — параллельные рёбра, ⌥ — все рёбра или вершины,
//  клик по грани — её 4 ребра, тянуть ручку внутрь — значение. Esc — выход.
//
//  Референс-изображения: клик по картинке — как по пустому месту, двойной клик выделяет её,
//  клик по точке разметки выделяет картинку и точку. Выделенную картинку тянут по её
//  плоскости. P — ставить точки, R — калибровка по двум точкам. Файл картинки можно
//  бросить на вьюпорт.
//

import SwiftUI
import MetalKit
import AppKit
import simd
import UniformTypeIdentifiers

struct ViewportView: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> ViewportNSView {
        ViewportNSView(model: model)
    }

    func updateNSView(_ view: ViewportNSView, context: Context) {
        // Чтение подписывает представление на изменения выделения и результата ядра.
        _ = model.selection
        _ = model.output.generation
        _ = model.filletTarget
        _ = model.filletSelection
        _ = model.outlineMode
        _ = model.selectedReference
        _ = model.markerSelection
        _ = model.referenceTool
        _ = model.calibrationPoints
        view.needsDisplay = true
        view.overlay.needsDisplay = true
        view.referenceOverlay.needsDisplay = true
    }
}

final class ViewportNSView: MTKView {
    private enum DragMode {
        case none
        case orbit
        case pan
        case deselectOrOrbit
        case move(anchor: Vec3, vertical: Bool)
        case fillet(origin: NSPoint, inward: CGVector, element: FilletElement)
        /// Картинку тянут по её плоскости.
        case referenceMove(anchor: Vec3, normal: Vec3)
        /// Точку разметки тянут по плоскости её картинки.
        case marker(MarkerRef)
    }

    private let model: EditorModel
    private var renderer: Renderer?
    private var dragMode: DragMode = .none
    private var mouseDownPoint: NSPoint = .zero
    private var dragged = false
    let overlay = FilletOverlayView()
    let referenceOverlay = ReferenceOverlayView()
    private var valueField: NSTextField?
    /// Поле длины при калибровке: висит над серединой линейки.
    private var calibrationField: NSTextField?
    /// Курсор-перекрестие поставлен нами — его надо вернуть.
    private var crosshair = false
    /// Повторный клик в ту же точку перебирает наложившиеся ручки.
    private var lastHandleClick: (point: NSPoint, index: Int)?

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
        referenceOverlay.model = model
        referenceOverlay.frame = bounds
        referenceOverlay.autoresizingMask = [.width, .height]
        addSubview(referenceOverlay)
        overlay.model = model
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        registerForDraggedTypes([.fileURL])
        model.redrawHandler = { [weak self] in
            self?.needsDisplay = true
            self?.overlay.needsDisplay = true
            self?.referenceOverlay.needsDisplay = true
            self?.positionCalibrationField()
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateReferenceHover(at: point)
        guard model.activeFilletNode != nil else {
            if overlay.hovered != nil { overlay.hovered = nil; overlay.needsDisplay = true }
            return
        }
        overlay.cursor = point
        overlay.hovered = FilletScene.build(model, size: bounds.size)?.handles(at: point).first?.element
        overlay.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        overlay.hovered = nil
        overlay.cursor = nil
        overlay.needsDisplay = true
        referenceOverlay.hovered = nil
        referenceOverlay.cursor = nil
        referenceOverlay.needsDisplay = true
        setCrosshair(false)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        dragged = false
        let flags = event.modifierFlags

        // Открыто поле длины калибровки: вьюпорт можно только вращать, фокус остаётся в поле.
        if calibrationField != nil {
            dragMode = flags.contains(.shift) ? .pan : .orbit
            return
        }
        window?.makeFirstResponder(self)

        if model.activeFilletNode != nil, filletMouseDown(event, at: point) {
            return
        }

        if referenceMouseDown(event, at: point) {
            return
        }

        guard let hit = model.pick(worldRay(point)) else {
            dragMode = flags.contains(.shift) ? .pan : .deselectOrOrbit
            return
        }
        let target = model.selectionTarget(for: hit.path, deep: event.clickCount >= 2)
        // Двойной клик по уже выделенному блоку — режим скруглений.
        if event.clickCount >= 2, model.selection == [target], model.doc.node(target)?.kind == .box {
            model.enterFilletMode(target)
            dragMode = .none
            return
        }
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
        case let .fillet(origin, inward, element):
            if overlay.dragging == nil {
                overlay.dragging = element
                model.beginFilletDrag()
            }
            // Смещение мыши вдоль направления «внутрь», в миллиметрах значения.
            let length2 = inward.dx * inward.dx + inward.dy * inward.dy
            let delta = ((point.x - origin.x) * inward.dx + (point.y - origin.y) * inward.dy) / max(length2, 1e-6)
            model.updateFilletDrag(delta: Double(delta), step: event.modifierFlags.contains(.shift) ? 1 : 0.5)
        case let .referenceMove(anchor, normal):
            if let hit = ViewportNSView.intersect(worldRay(point), planePoint: anchor, normal: normal, minimumCosine: 0.02) {
                model.updateReferenceMove(worldDelta: hit - anchor, snap: !event.modifierFlags.contains(.option))
            }
        case let .marker(ref):
            let ray = worldRay(point)
            // Почти вдоль плоскости пересечение улетает в бесконечность — такие шаги пропускаем.
            if let reference = model.doc.reference(ref.reference), abs(ray.dir.dot(reference.axes.normal)) > 0.02,
               let hit = reference.planeHit(ray) {
                model.moveMarker(ref.marker, in: ref.reference, to: hit.pixel)
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
        case .fillet:
            if overlay.dragging != nil {
                overlay.dragging = nil
                model.endFilletDrag()
            }
        case .referenceMove:
            model.endReferenceMove()
        case .marker:
            model.breakCoalescing()
        case .deselectOrOrbit:
            // Клик по пустому месту в режиме скруглений — выход из режима, блок остаётся выделен.
            if !dragged {
                if model.activeFilletNode != nil {
                    model.exitFilletMode()
                } else {
                    model.select(nil)
                }
            }
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

        if model.activeFilletNode != nil, filletKeyDown(event, flags: flags) {
            return
        }

        if referenceKeyDown(event, flags: flags) {
            return
        }

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
        case 46: model.toggleMask()       // M
        case 5: model.groupSelection()    // G
        case 3: model.frameSelection()    // F
        case 18: model.setView(.iso)      // 1
        case 19: model.setView(.top)      // 2
        case 20: model.setView(.front)    // 3
        case 21: model.setView(.right)    // 4
        case 49: model.toggleOutlineMode() // пробел
        default: super.keyDown(with: event)
        }
    }

    // MARK: Режим скруглений

    /// true — клик разобран режимом скруглений.
    private func filletMouseDown(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let node = model.activeFilletNode, let scene = FilletScene.build(model, size: bounds.size) else { return false }
        let flags = event.modifierFlags
        finishValueEntry(commit: true)

        switch overlay.badgePart(at: point) {
        case .value:
            beginValueEntry(initial: nil)
            return true
        case .menu:
            showKindMenu(at: point)
            return true
        case .hint:
            model.replaceBottomWithChamfer()
            return true
        case nil:
            break
        }

        let candidates = scene.handles(at: point)
        if !candidates.isEmpty {
            var index = 0
            if let last = lastHandleClick, hypot(last.point.x - point.x, last.point.y - point.y) < 4,
               candidates.count > 1, event.clickCount == 1 {
                index = (last.index + 1) % candidates.count
            }
            lastHandleClick = (point, index)
            let handle = candidates[index]
            let element = handle.element
            if flags.contains(.option) {
                // ⌥ — все рёбра или все вершины; нажатая ручка остаётся активной.
                let all: [FilletElement]
                switch element {
                case .edge: all = (0..<12).map { .edge($0) }
                case .vertex: all = (0..<8).map { .vertex($0) }
                }
                model.selectFillet(all.filter { $0 != element } + [element], extend: false)
            } else if event.clickCount >= 2, case .edge(let e) = element {
                model.selectFillet(BoxRounding.parallelEdges(e).filter { $0 != e }.map { .edge($0) } + [element], extend: false)
            } else if flags.contains(.shift) {
                model.selectFillet([element], extend: true)
            } else if !model.filletSelection.contains(element) {
                model.selectFillet([element], extend: false)
            } else {
                // Уже выбрана: делаем активной, выбор не теряем — так тянут группу.
                model.selectFillet(model.filletSelection.filter { $0 != element } + [element], extend: false)
            }
            if model.filletSelection.contains(element) {
                dragMode = .fillet(origin: point, inward: handle.inward, element: element)
            } else {
                dragMode = .none
            }
            return true
        }
        lastHandleClick = nil

        // Клик по грани блока — её 4 ребра; нижняя грань видна сквозь тело.
        if let hit = model.pick(worldRay(point)), hit.path.last == node.id {
            let local = model.doc.worldPose(of: node.id).inverse.apply(hit.point)
            let h = node.size * 0.5
            var axis = 0
            for a in 1..<3 where abs(local[a]) / max(h[a], 1e-9) > abs(local[axis]) / max(h[axis], 1e-9) {
                axis = a
            }
            let edges = BoxRounding.faceEdges(axis: axis, sign: local[axis] >= 0 ? 1 : -1).map { FilletElement.edge($0) }
            model.selectFillet(edges, extend: flags.contains(.shift))
            dragMode = .orbit
            return true
        }
        if model.pick(worldRay(point)) != nil {
            // Другой объект: выходим из режима, клик дальше выделяет его как обычно.
            model.exitFilletMode()
            return false
        }
        dragMode = flags.contains(.shift) ? .pan : .deselectOrOrbit
        return true
    }

    /// ⌘A из меню Edit: в режиме скруглений — все 12 рёбер, у выделенной картинки — все её точки.
    override func selectAll(_ sender: Any?) {
        if model.activeFilletNode != nil {
            model.selectFillet((0..<12).map { .edge($0) }, extend: false)
        } else if model.selectedReference != nil {
            model.selectAllMarkers()
        }
    }

    /// true — клавиша разобрана режимом скруглений.
    private func filletKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let hasSelection = !model.filletSelection.isEmpty
        switch event.keyCode {
        case 53:
            model.exitFilletMode()
            return true
        case 0 where flags.contains(.command):
            model.selectFillet((0..<12).map { .edge($0) }, extend: false)
            return true
        case 51, 117:
            // ⌫ возвращает выбранным острое ребро и не удаляет сам блок.
            if hasSelection { model.setFilletValue(0) }
            return true
        case 126, 125:
            let delta: Double = (flags.contains(.shift) ? 1 : 0.5) * (event.keyCode == 126 ? 1 : -1)
            model.nudgeFilletValue(delta)
            return true
        case 123, 124:
            return true
        default:
            break
        }
        if hasSelection, !flags.contains(.command), !flags.contains(.control),
           let characters = event.characters, let first = characters.first,
           first.isNumber || first == "." || first == "," {
            beginValueEntry(initial: characters)
            return true
        }
        return false
    }

    /// Поле ввода прямо на плашке: Enter — применить, Esc — отменить.
    private func beginValueEntry(initial: String?) {
        guard model.activeFilletNode != nil, !model.filletSelection.isEmpty else { return }
        overlay.display()
        var rect = overlay.valueRect
        if rect.isNull { rect = CGRect(x: bounds.midX - 50, y: bounds.midY, width: 100, height: 20) }
        let field = NSTextField(frame: rect.insetBy(dx: 4, dy: 0))
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = .white
        field.backgroundColor = NSColor(white: 0.16, alpha: 1)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        if let node = model.activeFilletNode, let first = model.filletSelection.last {
            field.stringValue = initial ?? Fmt.number(EditorModel.filletValue(first, node.rounding ?? BoxRounding()))
        }
        addSubview(field)
        valueField = field
        window?.makeFirstResponder(field)
        if initial != nil {
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }

    fileprivate func finishValueEntry(commit: Bool) {
        guard let field = valueField else { return }
        valueField = nil
        if commit, let value = ExpressionEvaluator.evaluate(field.stringValue) {
            model.setFilletValue(value)
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    /// Тип обработки: для рёбер — скругление или фаска, для вершин — авто или срез.
    private func showKindMenu(at point: NSPoint) {
        guard let node = model.activeFilletNode else { return }
        let rounding = node.rounding ?? BoxRounding()
        let edges = model.filletSelection.compactMap { if case .edge(let e) = $0 { return e } else { return nil } }
        let vertices = model.filletSelection.compactMap { if case .vertex(let v) = $0 { return v } else { return nil } }
        let menu = NSMenu()
        if !edges.isEmpty {
            menu.addItem(ActionMenuItem("Fillet", on: edges.allSatisfy { !rounding.chamfers[$0] && rounding.edges[$0] > 0 }) { [weak self] in
                self?.model.setFilletChamfer(false)
            })
            menu.addItem(ActionMenuItem("Chamfer 45°", on: edges.allSatisfy { rounding.chamfers[$0] && rounding.edges[$0] > 0 }) { [weak self] in
                self?.model.setFilletChamfer(true)
            })
        }
        if !vertices.isEmpty {
            if !edges.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ActionMenuItem("Auto corner", on: vertices.allSatisfy { rounding.cuts[$0] <= 0 }) { [weak self] in
                self?.model.setCornerCut(false)
            })
            menu.addItem(ActionMenuItem("Corner cut", on: vertices.allSatisfy { rounding.cuts[$0] > 0 }) { [weak self] in
                self?.model.setCornerCut(true)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Make sharp", on: false) { [weak self] in
            self?.model.setFilletValue(0)
        })
        menu.popUp(positioning: nil, at: point, in: self)
    }

    // MARK: Референсы

    /// true — клик разобран картинкой: её инструментом, точкой разметки или самой картинкой.
    private func referenceMouseDown(_ event: NSEvent, at point: NSPoint) -> Bool {
        let flags = event.modifierFlags
        let extend = flags.contains(.shift) || flags.contains(.command)
        let ray = worldRay(point)
        let marker = ReferenceOverlayView.marker(at: point, in: model, size: bounds.size)
        let navigate: DragMode = flags.contains(.shift) ? .pan : .orbit

        // Инструменты работают по выделенной картинке и сквозь тела: картинка часто под ними.
        if model.referenceTool != .none, let reference = model.selectedReferenceImage {
            let own = marker?.reference == reference.id ? marker : nil
            let hit = reference.planeHit(ray).flatMap { reference.contains($0.pixel) ? $0 : nil }
            switch model.referenceTool {
            case .points:
                if let own {
                    model.selectMarker(own.marker, extend: extend)
                    dragMode = model.markerSelection.contains(own.marker) ? .marker(own) : .none
                } else if let hit, let id = model.addMarker(at: hit.pixel) {
                    // Поставили — и сразу можно поправить, не отпуская кнопку.
                    dragMode = .marker(MarkerRef(reference: reference.id, marker: id))
                } else {
                    dragMode = navigate
                }
            case .calibrate:
                // Конец линейки прилипает к точке разметки: калибровать можно по поставленным точкам.
                if let own, let snapped = reference.markers.first(where: { $0.id == own.marker }) {
                    model.addCalibrationPoint(snapped.point)
                } else if let hit {
                    model.addCalibrationPoint(hit.pixel)
                } else {
                    dragMode = navigate
                    return true
                }
                dragMode = .none
                if model.calibrationPoints.count == 2 {
                    beginCalibrationEntry()
                }
            case .none:
                break
            }
            return true
        }

        // Точка любой видимой картинки: выделить картинку и точку, дальше — тянуть точку.
        if let marker {
            if model.selectedReference != marker.reference {
                model.selectReference(marker.reference, marker: marker.marker)
            } else {
                model.selectMarker(marker.marker, extend: extend)
            }
            dragMode = model.markerSelection.contains(marker.marker) ? .marker(marker) : .none
            return true
        }

        let nodeHit = model.pick(ray)
        let nodeDistance = nodeHit.map { ($0.point - ray.origin).length } ?? .infinity

        // Выделенная картинка, если она ближе тел, двигается по своей плоскости.
        if let reference = model.selectedReferenceImage, !reference.locked,
           let hit = reference.planeHit(ray), reference.contains(hit.pixel), hit.t < nodeDistance {
            if !model.markerSelection.isEmpty { model.selectMarkers([]) }
            model.beginReferenceMove(reference.id)
            dragMode = .referenceMove(anchor: hit.point, normal: reference.axes.normal)
            return true
        }

        // Двойной клик по картинке там, где нет тел, — выделить её.
        if nodeHit == nil, event.clickCount >= 2, let reference = model.pickReference(ray) {
            model.selectReference(reference.id)
            dragMode = .none
            return true
        }
        return false
    }

    /// true — клавиша разобрана инструментами референсов.
    private func referenceKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53, model.referenceTool != .none {
            model.setReferenceTool(.none)
            return true
        }
        guard model.selectedReference != nil, !flags.contains(.command), !flags.contains(.control) else { return false }
        switch event.keyCode {
        case 35: // P
            model.setReferenceTool(model.referenceTool == .points ? .none : .points)
            return true
        case 15: // R
            model.setReferenceTool(model.referenceTool == .calibrate ? .none : .calibrate)
            return true
        case 53 where !model.markerSelection.isEmpty:
            model.selectMarkers([])
            return true
        default:
            return false
        }
    }

    /// Подсветка точки под курсором и перекрестие над картинкой, пока включён инструмент.
    private func updateReferenceHover(at point: NSPoint) {
        let marker = ReferenceOverlayView.marker(at: point, in: model, size: bounds.size)
        let tool = model.referenceTool != .none
        if marker != referenceOverlay.hovered || marker != nil || tool {
            referenceOverlay.hovered = marker
            referenceOverlay.cursor = point
            referenceOverlay.needsDisplay = true
        }
        var overImage = false
        if tool, let reference = model.selectedReferenceImage, let hit = reference.planeHit(worldRay(point)) {
            overImage = reference.contains(hit.pixel)
        }
        setCrosshair(overImage && marker == nil)
    }

    private func setCrosshair(_ on: Bool) {
        if on {
            NSCursor.crosshair.set()
        } else if crosshair {
            NSCursor.arrow.set()
        }
        crosshair = on
    }

    /// Поле длины над серединой линейки: число уже набрано в текущем масштабе и выделено.
    private func beginCalibrationEntry() {
        guard calibrationField == nil, let reference = model.selectedReferenceImage,
              model.calibrationPoints.count == 2 else { return }
        let length = model.calibrationPoints[0].distance(to: model.calibrationPoints[1]) * reference.mmPerPixel
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 96, height: 22))
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = .white
        field.backgroundColor = NSColor(white: 0.16, alpha: 1)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "mm"
        field.stringValue = Fmt.number(length)
        field.toolTip = "The real distance between the two points, mm. Return — apply, Esc — cancel"
        field.delegate = self
        addSubview(field)
        calibrationField = field
        referenceOverlay.editingLength = true
        positionCalibrationField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Поле следует за линейкой, когда вращают камеру; без калибровки оно закрывается.
    private func positionCalibrationField() {
        guard let field = calibrationField else { return }
        guard model.referenceTool == .calibrate, model.calibrationPoints.count == 2,
              let reference = model.selectedReferenceImage else {
            closeCalibrationField()
            return
        }
        let view = ViewportGeometry(camera: model.camera, size: bounds.size)
        guard let a = view.project(reference.world(model.calibrationPoints[0])),
              let b = view.project(reference.world(model.calibrationPoints[1])) else { return }
        var frame = field.frame
        frame.origin = CGPoint(x: (a.x + b.x) / 2 - frame.width / 2, y: (a.y + b.y) / 2 + 12)
        frame.origin.x = min(max(frame.origin.x, 6), bounds.width - frame.width - 6)
        frame.origin.y = min(max(frame.origin.y, 6), bounds.height - frame.height - 6)
        field.frame = frame
    }

    fileprivate func finishCalibrationEntry(commit: Bool) {
        guard let field = calibrationField else { return }
        if commit {
            guard let value = ExpressionEvaluator.evaluate(field.stringValue), value > 0 else {
                NSSound.beep()
                return
            }
            closeCalibrationField()
            model.finishCalibration(value)
        } else {
            closeCalibrationField()
            model.setReferenceTool(.none)
        }
    }

    private func closeCalibrationField() {
        guard let field = calibrationField else { return }
        calibrationField = nil
        referenceOverlay.editingLength = false
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    // MARK: Перетаскивание файлов

    private func droppedImages(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.pdf.identifier],
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImages(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedImages(sender)
        guard !urls.isEmpty else { return false }
        model.importReferenceImages(urls)
        return true
    }

    // MARK: Геометрия экрана

    private func worldRay(_ point: NSPoint) -> Ray {
        ViewportGeometry(camera: model.camera, size: bounds.size).ray(point)
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

    /// minimumCosine — насколько луч должен не лежать в плоскости: почти вдоль неё точка улетает.
    private static func intersect(_ ray: Ray, planePoint: Vec3, normal: Vec3, minimumCosine: Double = 0) -> Vec3? {
        let denom = ray.dir.dot(normal)
        guard abs(denom) > max(1e-9, minimumCosine) else { return nil }
        let t = (planePoint - ray.origin).dot(normal) / denom
        guard t > 0 else { return nil }
        return ray.origin + ray.dir * t
    }
}

extension ViewportNSView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Поле длины калибровки применяется только по Return: потеря фокуса его не закрывает.
        let calibration = control === calibrationField
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if calibration { finishCalibrationEntry(commit: false) } else { finishValueEntry(commit: false) }
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if calibration { finishCalibrationEntry(commit: true) } else { finishValueEntry(commit: true) }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) !== calibrationField else { return }
        finishValueEntry(commit: true)
    }
}

/// Пункт меню с замыканием вместо селектора.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
