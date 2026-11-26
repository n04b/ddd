//
//  EditorModel+References.swift
//  Референс-изображения: импорт, масштаб, калибровка по двум точкам, разметка.
//
//  Картинка — подложка, а не деталь: клик по ней во вьюпорте работает как клик
//  по пустому месту. Выделяют её в дереве, двойным кликом или по точке разметки.
//  Все правки идут через mutate(): у них есть отмена и автосохранение.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Инструмент разметки во вьюпорте.
enum ReferenceTool: Equatable {
    case none
    /// Клик по картинке ставит точку.
    case points
    /// Два клика — концы известного расстояния, потом ввод его длины.
    case calibrate
}

extension EditorModel {
    var selectedReferenceImage: ReferenceImage? {
        selectedReference.flatMap { doc.reference($0) }
    }

    /// Подсказка инструмента под тулбаром.
    var referenceToolHint: String? {
        switch referenceTool {
        case .none:
            return nil
        case .points:
            return "Click the image to add a point · drag a point to move it · ⌫ deletes · Esc — done"
        case .calibrate:
            switch calibrationPoints.count {
            case 0: return "Calibrate: click one end of a known distance · Esc — cancel"
            case 1: return "Click the other end"
            default: return "Type the real distance and press Return"
            }
        }
    }

    // MARK: Импорт

    func importReferenceImages() {
        let panel = NSOpenPanel()
        panel.title = "Import Reference Image"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            self.importReferenceImages(panel.urls)
        }
    }

    /// Картинки ложатся на плоскость, которая смотрит на камеру; масштаб — по DPI из файла.
    func importReferenceImages(_ urls: [URL]) {
        var imported: [ReferenceImage] = []
        var failed: [String] = []
        let plane = preferredReferencePlane()
        var offset = 0.0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let info = ReferenceDecoder.inspect(data),
                  let key = try? ImageAssets.store(data) else {
                failed.append(url.lastPathComponent)
                continue
            }
            var reference = ReferenceImage(name: url.deletingPathExtension().lastPathComponent, asset: key,
                                           pixelWidth: info.width, pixelHeight: info.height, fileDPI: info.dpi)
            reference.plane = plane
            reference.center = reference.defaultCenter
            // Несколько картинок встают рядом, а не друг на друга.
            if !imported.isEmpty {
                offset += reference.width / 2
                reference.center = (reference.center + plane.basis.right * offset).cleaned
            }
            offset += reference.width / 2 + 10
            imported.append(reference)
        }
        guard let last = imported.last else {
            showToast("Could not import \(failed.first ?? "the file"): not a supported image")
            return
        }
        let added = imported
        mutate { $0.references.append(contentsOf: added) }
        selectReference(last.id)
        frameReferences(added.map(\.id))
        if !failed.isEmpty {
            showToast("Not an image: \(failed.joined(separator: ", "))")
        } else if added.count == 1 {
            showToast("\(last.name): \(Fmt.number(last.dpi)) dpi → \(Fmt.number(last.width)) × \(Fmt.number(last.height)) mm. "
                      + "R — calibrate by a known distance", undo: true)
        } else {
            showToast("Imported \(added.count) images", undo: true)
        }
    }

    /// Плоскость, которая лучше всего смотрит на камеру; в изометрии — стол.
    private func preferredReferencePlane() -> ReferencePlane {
        let back = camera.basis.back
        if abs(back.z) >= 0.5 { return .top }
        return abs(back.y) >= abs(back.x) ? .front : .right
    }

    // MARK: Выделение

    func selectReference(_ id: UUID?, marker: UUID? = nil) {
        if !selection.isEmpty { selection = [] }
        dropStaleFilletMode()
        if selectedReference != id {
            referenceTool = .none
            calibrationPoints = []
        }
        selectedReference = id
        markerSelection = marker.map { [$0] } ?? []
        requestRedraw()
    }

    /// Снимает выделение картинки вместе с её инструментами.
    func clearReferenceSelection() {
        guard selectedReference != nil || referenceTool != .none || !markerSelection.isEmpty else { return }
        selectedReference = nil
        markerSelection = []
        referenceTool = .none
        calibrationPoints = []
    }

    /// ⇧ или ⌘ — добавить или снять, иначе выбор заменяется.
    func selectMarker(_ id: UUID, extend: Bool) {
        if extend {
            if let index = markerSelection.firstIndex(of: id) {
                markerSelection.remove(at: index)
            } else {
                markerSelection.append(id)
            }
        } else {
            markerSelection = [id]
        }
        requestRedraw()
    }

    func selectMarkers(_ ids: [UUID]) {
        markerSelection = ids
        requestRedraw()
    }

    func selectAllMarkers() {
        guard let reference = selectedReferenceImage else { return }
        selectMarkers(reference.markers.map(\.id))
    }

    /// Ближайшая видимая картинка под лучом — для двойного клика.
    func pickReference(_ ray: Ray) -> ReferenceImage? {
        var best: (reference: ReferenceImage, t: Double)?
        for reference in doc.references where reference.visible && reference.opacity > 0.01 {
            guard let hit = reference.planeHit(ray), reference.contains(hit.pixel),
                  hit.t < (best?.t ?? .infinity) else { continue }
            best = (reference, hit.t)
        }
        return best?.reference
    }

    // MARK: Инструменты

    func setReferenceTool(_ tool: ReferenceTool) {
        guard selectedReference != nil || tool == .none else { return }
        referenceTool = tool
        calibrationPoints = []
        requestRedraw()
    }

    func addCalibrationPoint(_ point: Point2) {
        guard referenceTool == .calibrate else { return }
        if calibrationPoints.count >= 2 { calibrationPoints = [] }
        calibrationPoints.append(point)
        requestRedraw()
    }

    /// Длина введена: масштаб по двум точкам калибровки, инструмент закрывается.
    func finishCalibration(_ distance: Double) {
        guard let id = selectedReference, calibrationPoints.count == 2 else { return }
        let ends = calibrationPoints
        referenceTool = .none
        calibrationPoints = []
        calibrate(id, from: ends[0], to: ends[1], distance: distance)
    }

    /// Масштаб такой, чтобы между точками было `distance` мм. Первая точка остаётся на месте.
    func calibrate(_ id: UUID, from a: Point2, to b: Point2, distance: Double, coalesce: Bool = false) {
        guard let reference = doc.reference(id) else { return }
        let pixels = a.distance(to: b)
        guard distance > 0, pixels > 0.5 else {
            showToast("Pick two different points to calibrate")
            return
        }
        let dpi = 25.4 * pixels / distance
        let anchor = reference.world(a)
        mutate(coalesce: coalesce ? "calibrate-\(id)" : nil) { document in
            document.updateReference(id) { r in
                r.dpi = dpi
                r.center = (r.center + (anchor - r.world(a))).cleaned
            }
        }
        if !coalesce, let scaled = doc.reference(id) {
            showToast("Scale: \(Fmt.number(scaled.dpi)) dpi — the image is \(Fmt.number(scaled.width)) × \(Fmt.number(scaled.height)) mm",
                      undo: true)
        }
    }

    // MARK: Точки разметки

    /// Ставит точку на выделенной картинке; её сразу можно тянуть тем же движением.
    @discardableResult
    func addMarker(at point: Point2) -> UUID? {
        guard let id = selectedReference, let reference = doc.reference(id) else { return nil }
        let p = reference.clamped(point)
        let marker = ReferenceMarker(label: reference.nextMarkerLabel(), x: EditorModel.roundPixel(p.x), y: EditorModel.roundPixel(p.y))
        // Тот же ключ, что у перетаскивания: «поставил и поправил» отменяется одним шагом.
        mutate(coalesce: "marker-\(marker.id)") { document in
            document.updateReference(id) { $0.markers.append(marker) }
        }
        markerSelection = [marker.id]
        requestRedraw()
        return marker.id
    }

    func moveMarker(_ markerID: UUID, in referenceID: UUID, to point: Point2) {
        mutate(coalesce: "marker-\(markerID)") { document in
            document.updateReference(referenceID) { reference in
                guard let index = reference.markers.firstIndex(where: { $0.id == markerID }) else { return }
                let p = reference.clamped(point)
                reference.markers[index].point = Point2(EditorModel.roundPixel(p.x), EditorModel.roundPixel(p.y))
            }
        }
    }

    func renameMarker(_ markerID: UUID, in referenceID: UUID, _ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { document in
            document.updateReference(referenceID) { reference in
                guard let index = reference.markers.firstIndex(where: { $0.id == markerID }) else { return }
                reference.markers[index].label = trimmed
            }
        }
    }

    func deleteMarkers(_ ids: [UUID], in referenceID: UUID) {
        let doomed = Set(ids)
        mutate { document in
            document.updateReference(referenceID) { $0.markers.removeAll { doomed.contains($0.id) } }
        }
        markerSelection.removeAll { doomed.contains($0) }
        requestRedraw()
    }

    func deleteSelectedMarkers() {
        guard let id = selectedReference, !markerSelection.isEmpty else { return }
        let count = markerSelection.count
        deleteMarkers(markerSelection, in: id)
        showToast(count == 1 ? "Point deleted" : "Deleted \(count) points", undo: true)
    }

    /// Сдвигает картинку в её плоскости так, чтобы точка встала в начало координат:
    /// сверху — в X 0, Y 0; спереди и справа — на стол по центру.
    func moveReferenceOrigin(to markerID: UUID, in referenceID: UUID) {
        guard let reference = doc.reference(referenceID),
              let marker = reference.markers.first(where: { $0.id == markerID }) else { return }
        let point = reference.world(marker.point)
        let basis = reference.plane.basis
        let shift = -(basis.right * point.dot(basis.right) + basis.up * point.dot(basis.up))
        mutate { document in
            document.updateReference(referenceID) { $0.center = ($0.center + shift).cleaned }
        }
        showToast("Point \(marker.label) is now at the origin", undo: true)
    }

    /// Расстояние между двумя выделенными точками в мм.
    var selectedMarkerDistance: (from: ReferenceMarker, to: ReferenceMarker, millimeters: Double)? {
        guard markerSelection.count == 2, let reference = selectedReferenceImage,
              let a = reference.markers.first(where: { $0.id == markerSelection[0] }),
              let b = reference.markers.first(where: { $0.id == markerSelection[1] }) else { return nil }
        return (a, b, a.point.distance(to: b.point) * reference.mmPerPixel)
    }

    /// Точки хранятся с точностью до десятой пикселя.
    private static func roundPixel(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    // MARK: Свойства

    func renameReference(_ id: UUID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { $0.updateReference(id) { $0.name = trimmed } }
    }

    func setReferenceVisible(_ id: UUID, _ visible: Bool) {
        mutate { $0.updateReference(id) { $0.visible = visible } }
    }

    func setReferenceLocked(_ id: UUID, _ locked: Bool) {
        mutate { $0.updateReference(id) { $0.locked = locked } }
    }

    func setReferenceOnTop(_ id: UUID, _ onTop: Bool) {
        mutate { $0.updateReference(id) { $0.onTop = onTop } }
    }

    func setReferenceOpacity(_ id: UUID, percent: Double) {
        let value = min(max(percent / 100, 0), 1)
        mutate(coalesce: "reference-opacity-\(id)") { $0.updateReference(id) { $0.opacity = value } }
    }

    /// Новая плоскость — и место по умолчанию на ней: на столе или в начале координат.
    func setReferencePlane(_ id: UUID, _ plane: ReferencePlane) {
        mutate { document in
            document.updateReference(id) { reference in
                guard reference.plane != plane else { return }
                reference.plane = plane
                reference.center = reference.defaultCenter
            }
        }
    }

    func setReferenceCenter(_ id: UUID, axis: Int, _ value: Double) {
        mutate(coalesce: "reference-center-\(axis)-\(id)") { $0.updateReference(id) { $0.center[axis] = value } }
    }

    func setReferenceDPI(_ id: UUID, _ dpi: Double) {
        let value = min(max(dpi, 0.01), 1_000_000)
        updateKeepingBed(id, coalesce: "reference-dpi-\(id)") { $0.dpi = value }
    }

    func setReferenceWidth(_ id: UUID, _ millimeters: Double) {
        guard millimeters > 0 else { return }
        updateKeepingBed(id, coalesce: "reference-width-\(id)") { $0.dpi = Double($0.pixelWidth) * 25.4 / millimeters }
    }

    func setReferenceHeight(_ id: UUID, _ millimeters: Double) {
        guard millimeters > 0 else { return }
        updateKeepingBed(id, coalesce: "reference-height-\(id)") { $0.dpi = Double($0.pixelHeight) * 25.4 / millimeters }
    }

    func resetReferenceScale(_ id: UUID) {
        updateKeepingBed(id, coalesce: nil) { $0.dpi = $0.fileDPI }
    }

    func setReferenceAngle(_ id: UUID, _ degrees: Double) {
        let angle = EditorModel.normalizedAngle(degrees)
        updateKeepingBed(id, coalesce: "reference-angle-\(id)") { $0.angle = angle }
    }

    func rotateReference(_ id: UUID, by degrees: Double) {
        updateKeepingBed(id, coalesce: nil) { $0.angle = EditorModel.normalizedAngle($0.angle + degrees) }
    }

    func flipReference(_ id: UUID) {
        mutate { $0.updateReference(id) { $0.flipped.toggle() } }
    }

    /// Масштаб и поворот — вокруг центра. Картинка, стоявшая на столе, на нём и остаётся.
    private func updateKeepingBed(_ id: UUID, coalesce: String?, _ body: (inout ReferenceImage) -> Void) {
        mutate(coalesce: coalesce) { document in
            document.updateReference(id) { reference in
                let onBed = reference.halfHeightZ > 1e-6 && abs(reference.bottomZ) < 1e-3
                body(&reference)
                if onBed {
                    reference.center.z = Vec3.clean(reference.halfHeightZ)
                }
            }
        }
    }

    /// Угол в диапазоне (−180, 180].
    private static func normalizedAngle(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a <= -180 { a += 360 }
        if a > 180 { a -= 360 }
        return Vec3.clean(a)
    }

    // MARK: Структура

    func deleteReference(_ id: UUID) {
        guard let reference = doc.reference(id) else { return }
        mutate { $0.references.removeAll { $0.id == id } }
        if selectedReference == id {
            clearReferenceSelection()
        }
        requestRedraw()
        showToast("Deleted: \(reference.name)", undo: true)
    }

    func duplicateReference(_ id: UUID) {
        guard let original = doc.reference(id) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " copy"
        copy.markers = original.markers.map { marker in
            var m = marker
            m.id = UUID()
            return m
        }
        copy.center = (copy.center + original.plane.basis.right * 10).cleaned
        let duplicate = copy
        mutate { document in
            let index = (document.references.firstIndex { $0.id == id } ?? document.references.count - 1) + 1
            document.references.insert(duplicate, at: index)
        }
        selectReference(duplicate.id)
    }

    // MARK: Перемещение во вьюпорте

    func beginReferenceMove(_ id: UUID) {
        guard let reference = doc.reference(id) else { return }
        referenceMoveStart = (id, reference.center)
        breakCoalescing()
    }

    /// Смещение в мире; по умолчанию шаг 1 мм, как у объектов.
    func updateReferenceMove(worldDelta: Vec3, snap: Bool) {
        guard let start = referenceMoveStart else { return }
        let delta = snap ? Vec3(worldDelta.x.rounded(), worldDelta.y.rounded(), worldDelta.z.rounded()) : worldDelta
        mutate(coalesce: "reference-move") { document in
            document.updateReference(start.id) { $0.center = (start.center + delta).cleaned }
        }
    }

    func endReferenceMove() {
        referenceMoveStart = nil
        breakCoalescing()
    }

    func nudgeReference(_ id: UUID, _ delta: Vec3) {
        guard let reference = doc.reference(id) else { return }
        guard !reference.locked else {
            showToast("\(reference.name) is locked")
            return
        }
        mutate { $0.updateReference(id) { $0.center = ($0.center + delta).cleaned } }
    }

    // MARK: Камера

    func frameReference(_ id: UUID) {
        frameReferences([id])
    }

    func frameReferences(_ ids: [UUID]) {
        var box = AABB.empty
        for id in ids {
            if let reference = doc.reference(id) { box.formUnion(reference.bounds) }
        }
        guard !box.isEmpty else { return }
        var goal = camera
        goal.frame(box)
        animateCamera(to: goal)
    }
}
