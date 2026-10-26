//
//  EditorModel.swift
//  Состояние редактора: документ, выделение, история, связь с ядром и файлами.
//  Все правки документа идут через mutate(), там же история и пересчёт.
//

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

enum ViewPreset {
    case iso
    case top
    case front
    case right
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let canUndo: Bool
}

@Observable
final class EditorModel {
    private(set) var doc: SceneDocument
    var selection: [UUID] = []
    var expanded: Set<UUID> = []
    var renamingID: UUID?
    var toast: Toast?
    private(set) var output = KernelOutput()
    private(set) var isComputing = false
    private(set) var undoStack: [SceneDocument] = []
    private(set) var redoStack: [SceneDocument] = []

    @ObservationIgnored var camera = OrbitCamera()
    @ObservationIgnored var redrawHandler: (() -> Void)?
    @ObservationIgnored private var worker: KernelWorker?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var coalesceKey: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var moveStart: [UUID: Vec3] = [:]
    @ObservationIgnored private var projectURL: URL?
    @ObservationIgnored private var needsInitialFrame = true

    init() {
        doc = Persistence.loadAutosave() ?? SceneDocument.demo()
        expanded = Set(doc.allNodes().filter { $0.kind == .group }.map(\.id))
        worker = KernelWorker { [unowned self] result in
            Task { @MainActor in
                self.receive(result)
            }
        }
        scheduleEvaluation()
    }

    // MARK: Производные значения

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var primaryID: UUID? { selection.last }
    var primary: Node? { primaryID.flatMap { doc.node($0) } }

    /// Треугольники печатаемых деталей.
    var partTriangles: Int {
        doc.nodes
            .filter { $0.visible && $0.mode == .solid }
            .reduce(0) { $0 + (output.meshes[$1.id]?.triangleCount ?? 0) }
    }

    func isTopLevel(_ id: UUID) -> Bool {
        doc.nodes.contains { $0.id == id }
    }

    /// Габариты узла в мировых координатах.
    func bounds(of id: UUID) -> AABB? {
        guard let local = output.meshes[id]?.bounds, !local.isEmpty else { return nil }
        return local.transformed(by: doc.worldPose(of: id))
    }

    // MARK: История

    func mutate(coalesce key: String? = nil, _ body: (inout SceneDocument) -> Void) {
        var next = doc
        body(&next)
        guard next != doc else { return }
        if key == nil || key != coalesceKey {
            undoStack.append(doc)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        coalesceKey = key
        doc = next
        documentChanged()
    }

    /// Следующая правка начнёт новый шаг истории.
    func breakCoalescing() {
        coalesceKey = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = previous
        coalesceKey = nil
        pruneSelection()
        documentChanged()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
        coalesceKey = nil
        pruneSelection()
        documentChanged()
    }

    private func documentChanged() {
        scheduleEvaluation()
        scheduleAutosave()
        requestRedraw()
    }

    // MARK: Ядро

    private func scheduleEvaluation() {
        generation += 1
        isComputing = true
        worker?.submit(doc, generation: generation)
    }

    private func receive(_ result: KernelOutput) {
        output = result
        if result.generation == generation {
            isComputing = false
        }
        if needsInitialFrame {
            needsInitialFrame = false
            frameAll()
        }
        requestRedraw()
    }

    func requestRedraw() {
        redrawHandler?()
    }

    // MARK: Выделение

    func select(_ id: UUID?) {
        selection = id.map { [$0] } ?? []
        if let id {
            for ancestor in doc.ancestors(of: id) { expanded.insert(ancestor) }
        }
        requestRedraw()
    }

    func toggleSelection(_ id: UUID) {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
        } else {
            selection.append(id)
        }
        requestRedraw()
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func pruneSelection() {
        selection = selection.filter { doc.node($0) != nil }
    }

    /// Выделенные узлы без тех, чей предок тоже выделен.
    private func topmostSelected() -> [UUID] {
        let selected = Set(selection)
        return selection.filter { id in
            doc.node(id) != nil && !doc.ancestors(of: id).contains { selected.contains($0) }
        }
    }

    func pick(_ ray: Ray) -> (path: [UUID], point: Vec3)? {
        guard let hit = Picking.pick(doc, ray: ray) else { return nil }
        return (hit.path, ray.origin + ray.dir * hit.t)
    }

    /// Какой узел выделять по клику, как в Figma: сначала верхний уровень,
    /// дальше — уровень текущего выделения; двойной клик — сам примитив.
    func selectionTarget(for path: [UUID], deep: Bool) -> UUID {
        if deep, let last = path.last { return last }
        if let hit = path.first(where: { selection.contains($0) }) { return hit }
        if let primaryID,
           let parent = doc.parentID(of: primaryID),
           let index = path.firstIndex(of: parent),
           index + 1 < path.count {
            return path[index + 1]
        }
        return path[0]
    }

    // MARK: Создание и структура

    func add(_ kind: NodeKind) {
        var node = Node(name: nextName(for: kind), kind: kind)
        node.size = Vec3(20, 20, 20)

        var parent: UUID?
        if let current = primary {
            parent = current.kind == .group ? current.id : doc.parentID(of: current.id)
        }

        let world: Vec3
        if let id = primaryID, let box = bounds(of: id) {
            world = Vec3((box.hi.x + node.size.x / 2 + 6).rounded(), box.center.y.rounded(), node.size.z / 2)
        } else {
            world = Vec3(Double(camera.target.x).rounded(), Double(camera.target.y).rounded(), node.size.z / 2)
        }
        let parentPose = parent.map { doc.worldPose(of: $0) } ?? .identity
        node.position = parentPose.inverse.apply(world).cleaned

        let newNode = node
        mutate { $0.insert(newNode, into: parent, at: nil) }
        select(newNode.id)
    }

    private func nextName(for kind: NodeKind) -> String {
        let count = doc.allNodes().filter { $0.kind == kind }.count
        return "\(kind.baseName) \(count + 1)"
    }

    func groupSelection() {
        let ids = topmostSelected()
        guard !ids.isEmpty else { return }
        let parents = Set(ids.map { doc.parentID(of: $0) })
        guard parents.count == 1, let parent = parents.first else {
            showToast("Группировать можно только объекты одного уровня")
            return
        }
        let siblings = doc.children(of: parent)
        let members = siblings.filter { ids.contains($0.id) }
        guard let firstIndex = siblings.firstIndex(where: { ids.contains($0.id) }) else { return }

        var center = Vec3.zero
        for member in members { center = center + member.position }
        center = center / Double(members.count)
        center = Vec3(center.x.rounded(), center.y.rounded(), center.z.rounded())

        var group = Node(name: nextName(for: .group), kind: .group)
        group.position = center
        group.children = members.map { member in
            var child = member
            child.position = (child.position - center).cleaned
            return child
        }

        let newGroup = group
        mutate { document in
            for id in ids { document.remove(id) }
            document.insert(newGroup, into: parent, at: firstIndex)
        }
        expanded.insert(newGroup.id)
        select(newGroup.id)
    }

    func ungroupSelection() {
        guard let id = primaryID, let group = doc.node(id), group.kind == .group,
              let index = doc.indexInParent(id) else { return }
        let parent = doc.parentID(of: id)
        let groupPose = group.pose
        let children = group.children.map { member -> Node in
            var child = member
            let composed = groupPose * child.pose
            child.position = composed.translation.cleaned
            child.rotation = composed.rotation.eulerDegrees.cleaned
            return child
        }
        mutate { document in
            document.remove(id)
            for (offset, child) in children.enumerated() {
                document.insert(child, into: parent, at: index + offset)
            }
        }
        selection = children.map(\.id)
        requestRedraw()
    }

    func duplicateSelection() {
        let ids = topmostSelected()
        guard !ids.isEmpty else { return }
        var copies: [UUID] = []
        mutate { document in
            for id in ids {
                guard let original = document.node(id) else { continue }
                var copy = original.withNewIDs()
                copy.name = original.name + " копия"
                copy.position.x += 10
                let index = (document.indexInParent(id) ?? 0) + 1
                document.insert(copy, into: document.parentID(of: id), at: index)
                copies.append(copy.id)
            }
        }
        selection = copies
        requestRedraw()
    }

    func deleteSelection() {
        let ids = topmostSelected()
        guard !ids.isEmpty else { return }
        let firstName = doc.node(ids[0])?.name ?? ""
        mutate { document in
            for id in ids { document.remove(id) }
        }
        selection = []
        showToast(ids.count == 1 ? "Удалено: \(firstName)" : "Удалено объектов: \(ids.count)", undo: true)
    }

    /// Перенос в другую группу (или на верхний уровень) с сохранением положения в мире.
    func moveNode(_ id: UUID, toParent parent: UUID?, before sibling: UUID?) {
        if let parent, parent == id || doc.isDescendant(parent, of: id) { return }
        if sibling == id { return }
        guard var node = doc.node(id) else { return }
        let world = doc.worldPose(of: id)
        let parentWorld = parent.map { doc.worldPose(of: $0) } ?? .identity
        let local = parentWorld.inverse * world
        node.position = local.translation.cleaned
        node.rotation = local.rotation.eulerDegrees.cleaned

        let moved = node
        mutate { document in
            document.remove(id)
            let index = sibling.flatMap { document.indexInParent($0) }
            document.insert(moved, into: parent, at: index)
        }
        if let parent { expanded.insert(parent) }
    }

    // MARK: Свойства

    func rename(_ id: UUID, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { document in
            document.update(id) { node in node.name = trimmed }
        }
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        mutate { document in
            document.update(id) { node in node.visible = visible }
        }
    }

    func setMode(_ ids: [UUID], _ mode: NodeMode) {
        mutate { document in
            for id in ids {
                document.update(id) { node in node.mode = mode }
            }
        }
        if mode == .hole, ids.contains(where: { isTopLevel($0) }) {
            showToast("Отверстие вырезает только внутри группы: выделите его вместе с телом (⌘-клик) и нажмите ⌘G")
        }
    }

    func toggleHole() {
        guard let current = primary else { return }
        setMode(topmostSelected(), current.mode == .solid ? .hole : .solid)
    }

    func setPosition(_ id: UUID, axis: Int, _ value: Double) {
        mutate(coalesce: "position-\(axis)-\(id)") { document in
            document.update(id) { node in node.position[axis] = value }
        }
    }

    func setRotation(_ id: UUID, axis: Int, _ value: Double) {
        mutate(coalesce: "rotation-\(axis)-\(id)") { document in
            document.update(id) { node in node.rotation[axis] = value }
        }
    }

    /// axis: 0 — X, 1 — Y, 2 — Z. У сферы любое значение — диаметр, у цилиндра X и Y — диаметр.
    func setSize(_ id: UUID, axis: Int, _ value: Double) {
        let v = max(value, 0.01)
        mutate(coalesce: "size-\(axis)-\(id)") { document in
            document.update(id) { node in
                switch node.kind {
                case .sphere:
                    node.size = Vec3(v, v, v)
                case .cylinder:
                    if axis == 2 {
                        node.size.z = v
                    } else {
                        node.size.x = v
                        node.size.y = v
                    }
                default:
                    node.size[axis] = v
                }
            }
        }
    }

    // MARK: Перемещение во вьюпорте

    func beginMove() {
        var starts: [UUID: Vec3] = [:]
        for id in topmostSelected() {
            if let node = doc.node(id) { starts[id] = node.position }
        }
        moveStart = starts
        breakCoalescing()
    }

    /// Смещение в мировых координатах; по умолчанию шаг 1 мм.
    func updateMove(worldDelta: Vec3, snap: Bool) {
        guard !moveStart.isEmpty else { return }
        let delta = snap ? Vec3(worldDelta.x.rounded(), worldDelta.y.rounded(), worldDelta.z.rounded()) : worldDelta
        let starts = moveStart
        mutate(coalesce: "move") { document in
            for (id, start) in starts {
                let parentPose = document.parentWorldPose(of: id)
                let local = parentPose.rotation.transposed * delta
                document.update(id) { node in node.position = (start + local).cleaned }
            }
        }
    }

    func endMove() {
        moveStart = [:]
        breakCoalescing()
    }

    func nudge(_ worldDelta: Vec3) {
        beginMove()
        updateMove(worldDelta: worldDelta, snap: false)
        endMove()
    }

    // MARK: Камера

    func frameAll() {
        frame(doc.nodes.filter(\.visible).map(\.id))
    }

    func frameSelection() {
        frame(selection.isEmpty ? doc.nodes.filter(\.visible).map(\.id) : selection)
    }

    private func frame(_ ids: [UUID]) {
        var box = AABB.empty
        for id in ids {
            if let b = bounds(of: id) { box.formUnion(b) }
        }
        if box.isEmpty {
            box = AABB(lo: Vec3(-40, -40, 0), hi: Vec3(40, 40, 40))
        }
        camera.frame(box)
        requestRedraw()
    }

    func setView(_ preset: ViewPreset) {
        switch preset {
        case .iso:
            camera.yaw = -Float.pi / 4
            camera.pitch = 0.6
        case .top:
            camera.yaw = -Float.pi / 2
            camera.pitch = OrbitCamera.maxPitch
        case .front:
            camera.yaw = -Float.pi / 2
            camera.pitch = 0
        case .right:
            camera.yaw = 0
            camera.pitch = 0
        }
        frameSelection()
    }

    // MARK: Уведомления

    func showToast(_ text: String, undo: Bool = false) {
        let item = Toast(text: text, canUndo: undo)
        toast = item
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.toast?.id == item.id {
                self?.toast = nil
            }
        }
    }

    // MARK: Файлы

    private func scheduleAutosave() {
        saveTask?.cancel()
        let snapshot = doc
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? Persistence.save(snapshot, to: Persistence.autosaveURL)
        }
    }

    func newProject() {
        replaceDocument(SceneDocument())
        projectURL = nil
        showToast("Новый проект", undo: true)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Открыть проект"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let loaded = try JSONDecoder().decode(SceneDocument.self, from: data)
                self.replaceDocument(loaded)
                self.projectURL = url
                self.showToast("Открыт: \(url.lastPathComponent)", undo: true)
            } catch {
                self.showToast("Не удалось открыть: \(error.localizedDescription)")
            }
        }
    }

    func saveProject() {
        if let url = projectURL {
            write(to: url)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.title = "Сохранить проект"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Проект.json"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.projectURL = url
            self.write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try Persistence.save(doc, to: url)
            showToast("Сохранено: \(url.lastPathComponent)")
        } catch {
            showToast("Не удалось сохранить: \(error.localizedDescription)")
        }
    }

    func exportSTL() {
        let meshes = doc.nodes
            .filter { $0.visible && $0.mode == .solid }
            .compactMap { node in output.meshes[node.id]?.transformed(by: node.pose) }
            .filter { $0.triangleCount > 0 }
        guard !meshes.isEmpty else {
            showToast("Нечего экспортировать: нет видимых тел")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Экспорт STL"
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        let base = projectURL?.deletingPathExtension().lastPathComponent ?? "model"
        panel.nameFieldStringValue = base + ".stl"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try STLWriter.binary(meshes).write(to: url, options: .atomic)
                self.showToast("Экспортировано: \(url.lastPathComponent)")
            } catch {
                self.showToast("Не удалось экспортировать: \(error.localizedDescription)")
            }
        }
    }

    private func replaceDocument(_ document: SceneDocument) {
        mutate { $0 = document }
        selection = []
        renamingID = nil
        expanded = Set(doc.allNodes().filter { $0.kind == .group }.map(\.id))
        needsInitialFrame = true
    }
}
