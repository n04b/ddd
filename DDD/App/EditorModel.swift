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

/// Ручка в режиме скруглений: ребро или вершина параллелепипеда.
enum FilletElement: Hashable {
    case edge(Int)
    case vertex(Int)
}

enum FilletPreset {
    case allEdges
    case topAndVertical
    case vertical
    case top
    /// Верх и вертикальные скруглены, низ — фаска 45°: печатается без поддержек.
    case print
    case reset
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
    /// Режим контуров: невыделенные отверстия и маски — одной линией,
    /// соседи выделенного по группе — заливкой. Переключается пробелом.
    var outlineMode = false
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
    @ObservationIgnored private var draftSubmitted = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var exportWhenReady = false

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
        // Слитые правки идут потоком (тянут поле, двигают мышью): пока считаем черновик.
        documentChanged(draft: key != nil)
    }

    /// Следующая правка начнёт новый шаг истории. Правка закончена — считаем точно.
    func breakCoalescing() {
        coalesceKey = nil
        settle()
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

    private func documentChanged(draft: Bool = false) {
        scheduleEvaluation(draft: draft)
        scheduleAutosave()
        requestRedraw()
    }

    // MARK: Ядро

    private func scheduleEvaluation(draft: Bool = false) {
        generation += 1
        isComputing = true
        draftSubmitted = draft
        worker?.submit(doc, generation: generation, draft: draft)
        settleTask?.cancel()
        settleTask = nil
        if draft {
            // Страховка: если конец правки не пришёл, точный расчёт после паузы.
            settleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.settle()
            }
        }
    }

    /// Заменяет черновик точным расчётом.
    private func settle() {
        guard draftSubmitted else { return }
        scheduleEvaluation()
    }

    private func receive(_ result: KernelOutput) {
        output = result
        if result.generation == generation {
            isComputing = false
            if !result.isDraft && exportWhenReady {
                exportWhenReady = false
                exportSTL()
            }
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
        dropStaleFilletMode()
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
        dropStaleFilletMode()
        requestRedraw()
    }

    /// Выделили другое — режим скруглений закрывается, а не ждёт возврата к блоку.
    private func dropStaleFilletMode() {
        if let target = filletTarget, selection != [target] {
            filletTarget = nil
            filletSelection = []
        }
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
            showToast("Only objects on the same level can be grouped")
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
                copy.name = original.name + " copy"
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
        showToast(ids.count == 1 ? "Deleted: \(firstName)" : "Deleted \(ids.count) objects", undo: true)
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

    func toggleOutlined(_ id: UUID) {
        mutate { document in
            document.update(id) { node in node.outlined = node.outlined == true ? nil : true }
        }
    }

    /// ⌥-клик по глазу: виден только этот объект — с предками, чтобы он не пропал
    /// вместе со скрытой группой, и с потомками. Повторный ⌥-клик показывает всё.
    func soloVisibility(_ id: UUID) {
        guard doc.node(id) != nil else { return }
        let keep = soloSet(id)
        let isSolo = doc.allNodes().allSatisfy { keep.contains($0.id) ? $0.visible : !$0.visible }
        mutate { document in
            for node in document.allNodes() {
                document.update(node.id) { $0.visible = isSolo || keep.contains(node.id) }
            }
        }
    }

    private func soloSet(_ id: UUID) -> Set<UUID> {
        var keep = Set(doc.ancestors(of: id))
        keep.insert(id)
        if let node = doc.node(id) {
            var stack = node.children
            while let child = stack.popLast() {
                keep.insert(child.id)
                stack.append(contentsOf: child.children)
            }
        }
        return keep
    }

    func setMode(_ ids: [UUID], _ mode: NodeMode) {
        mutate { document in
            for id in ids {
                document.update(id) { node in node.mode = mode }
            }
        }
        if mode == .hole, ids.contains(where: { isTopLevel($0) }) {
            showToast("A hole only cuts inside a group: select it together with a solid (⌘-click) and press ⌘G")
        }
        if mode == .mask, ids.contains(where: { isTopLevel($0) }) {
            showToast("A mask only clips inside a group: select it together with the objects to clip (⌘-click) and press ⌘G")
        }
    }

    func toggleHole() {
        guard let current = primary else { return }
        setMode(topmostSelected(), current.mode == .hole ? .solid : .hole)
    }

    /// Маска — 3D clipping mask: в группе остаётся только то, что внутри неё.
    func toggleMask() {
        guard let current = primary else { return }
        setMode(topmostSelected(), current.mode == .mask ? .solid : .mask)
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

    // MARK: Скругления

    /// Размер, с которым пресеты скругляют ещё острый блок.
    var roundingRadius: Double = 2
    /// Блок в режиме скруглений: полупрозрачный, с ручками на рёбрах и вершинах.
    private(set) var filletTarget: UUID?
    /// Выбранные ручки; последняя — активная, у неё плашка значения.
    private(set) var filletSelection: [FilletElement] = []
    @ObservationIgnored private var filletDragStart: (rounding: BoxRounding, values: [FilletElement: Double])?

    /// Выделенные блоки: пресеты применяются ко всем сразу.
    var roundableIDs: [UUID] {
        selection.filter { doc.node($0)?.kind == .box }
    }

    var hasRounding: Bool {
        roundableIDs.contains { doc.node($0)?.rounding != nil }
    }

    /// Режим скруглений жив, пока выделен ровно этот блок.
    var activeFilletNode: Node? {
        guard let id = filletTarget, selection == [id], let node = doc.node(id), node.kind == .box else { return nil }
        return node
    }

    /// Деталь, которую показываем рентгеном: сам блок или его группа верхнего уровня.
    var filletXrayPart: UUID? {
        guard let node = activeFilletNode else { return nil }
        return doc.ancestors(of: node.id).first ?? node.id
    }

    func enterFilletMode(_ id: UUID) {
        guard doc.node(id)?.kind == .box else { return }
        select(id)
        filletTarget = id
        filletSelection = []
        requestRedraw()
    }

    func exitFilletMode() {
        guard filletTarget != nil else { return }
        filletTarget = nil
        filletSelection = []
        breakCoalescing()
        requestRedraw()
    }

    /// Выбор ручек: ⇧ добавляет или снимает, иначе выбор заменяется.
    func selectFillet(_ elements: [FilletElement], extend: Bool) {
        guard activeFilletNode != nil else { return }
        if extend {
            if elements.count == 1, let index = filletSelection.firstIndex(of: elements[0]) {
                filletSelection.remove(at: index)
            } else {
                filletSelection.removeAll { elements.contains($0) }
                filletSelection.append(contentsOf: elements)
            }
        } else {
            filletSelection = elements
        }
        requestRedraw()
    }

    /// Текущее значение элемента: размер ребра, срез вершины или радиус угла «авто».
    static func filletValue(_ element: FilletElement, _ rounding: BoxRounding) -> Double {
        switch element {
        case .edge(let e):
            return rounding.edges[e]
        case .vertex(let v):
            if rounding.cuts[v] > 0 { return rounding.cuts[v] }
            return BoxRounding.vertexEdges(v).map { rounding.chamfers[$0] ? 0 : rounding.edges[$0] }.min() ?? 0
        }
    }

    /// Рёбра, которые меняет выборка: выбранные рёбра и рёбра вершин «авто».
    private static func affectedEdges(_ elements: [FilletElement], _ rounding: BoxRounding) -> Set<Int> {
        var result = Set<Int>()
        for element in elements {
            switch element {
            case .edge(let e): result.insert(e)
            case .vertex(let v) where rounding.cuts[v] <= 0: result.formUnion(BoxRounding.vertexEdges(v))
            default: break
            }
        }
        return result
    }

    /// Предел элемента, в который упирается ручка.
    func filletLimit(_ element: FilletElement, node: Node, growing: [FilletElement]? = nil) -> Double {
        let rounding = node.rounding ?? BoxRounding()
        let growingEdges = EditorModel.affectedEdges(growing ?? filletSelection, rounding)
        switch element {
        case .edge(let e):
            return rounding.maxEdge(e, size: node.size, growing: growingEdges)
        case .vertex(let v):
            if rounding.cuts[v] > 0 { return BoxRounding.maxCut(size: node.size) }
            return BoxRounding.vertexEdges(v).map { rounding.maxEdge($0, size: node.size, growing: growingEdges) }.min() ?? 0
        }
    }

    func beginFilletDrag() {
        guard let node = activeFilletNode else { return }
        let rounding = node.rounding ?? BoxRounding()
        var values: [FilletElement: Double] = [:]
        for element in filletSelection {
            values[element] = EditorModel.filletValue(element, rounding)
        }
        filletDragStart = (rounding, values)
    }

    /// Перетаскивание добавляет одинаковую дельту каждому выбранному и сохраняет
    /// разницу между ними; ручка упирается в предел.
    func updateFilletDrag(delta: Double, step: Double) {
        guard let node = activeFilletNode, let start = filletDragStart else { return }
        let id = node.id
        var startNode = node
        startNode.rounding = start.rounding
        var targets: [FilletElement: Double] = [:]
        for (element, value) in start.values {
            let limit = filletLimit(element, node: startNode, growing: Array(start.values.keys))
            let raw = ((value + delta) / step).rounded() * step
            targets[element] = min(max(raw, 0), max(limit, value))
        }
        mutate(coalesce: "fillet-\(id)") { document in
            document.update(id) { node in
                var rounding = start.rounding
                EditorModel.apply(targets, to: &rounding)
                node.rounding = rounding.isEmpty ? nil : rounding
            }
        }
    }

    func endFilletDrag() {
        filletDragStart = nil
        breakCoalescing()
    }

    /// Ввод числа: всем выбранным одно значение. Сверх предела не обрезается —
    /// геометрия строится с допустимым, а поле показывает «12 → 8».
    func setFilletValue(_ value: Double) {
        guard let node = activeFilletNode, !filletSelection.isEmpty else { return }
        let v = max(value, 0)
        var targets: [FilletElement: Double] = [:]
        for element in filletSelection { targets[element] = v }
        updateFillet(node.id) { EditorModel.apply(targets, to: &$0) }
    }

    func nudgeFilletValue(_ delta: Double) {
        guard activeFilletNode != nil, !filletSelection.isEmpty else { return }
        beginFilletDrag()
        updateFilletDrag(delta: delta, step: abs(delta))
        endFilletDrag()
    }

    private static func apply(_ targets: [FilletElement: Double], to rounding: inout BoxRounding) {
        for (element, value) in targets {
            switch element {
            case .edge(let e):
                rounding.edges[e] = value
            case .vertex(let v):
                if rounding.cuts[v] > 0 {
                    rounding.cuts[v] = value
                } else {
                    // Угол «авто» задаётся радиусом трёх своих рёбер.
                    for e in BoxRounding.vertexEdges(v) {
                        rounding.edges[e] = value
                        rounding.chamfers[e] = false
                    }
                }
            }
        }
    }

    /// Тип выбранных рёбер: скругление или фаска 45°.
    func setFilletChamfer(_ chamfer: Bool) {
        guard let node = activeFilletNode else { return }
        let fallback = node.rounding?.radius ?? roundingRadius
        let edges = filletSelection.compactMap { if case .edge(let e) = $0 { return e } else { return nil } }
        updateFillet(node.id) { rounding in
            for e in edges {
                rounding.chamfers[e] = chamfer
                if rounding.edges[e] <= 0 { rounding.edges[e] = fallback }
            }
        }
    }

    /// Тип выбранных вершин: «авто» или срез.
    func setCornerCut(_ cut: Bool) {
        guard let node = activeFilletNode else { return }
        let vertices = filletSelection.compactMap { if case .vertex(let v) = $0 { return v } else { return nil } }
        updateFillet(node.id) { rounding in
            for v in vertices {
                rounding.cuts[v] = cut ? max(rounding.cuts[v], 1) : 0
            }
        }
    }

    /// Нижние рёбра по мировой оси Z с учётом поворота детали: лежат на самом низу блока.
    func bottomEdges(of node: Node) -> [Int] {
        let pose = doc.worldPose(of: node.id)
        let h = node.size * 0.5
        var lowest = Double.infinity
        var ends: [(Double, Double)] = []
        for e in 0..<12 {
            let l = BoxRounding.edgeLayout(e)
            var a = Vec3.zero
            a[l.b] = l.sb * h[l.b]
            a[l.c] = l.sc * h[l.c]
            var b = a
            a[l.axis] = -h[l.axis]
            b[l.axis] = h[l.axis]
            let za = pose.apply(a).z
            let zb = pose.apply(b).z
            ends.append((za, zb))
            lowest = min(lowest, za, zb)
        }
        return (0..<12).filter { abs(ends[$0].0 - lowest) < 0.01 && abs(ends[$0].1 - lowest) < 0.01 }
    }

    /// Совет для печати: скругление больше 1 мм у стола заменить фаской 45°.
    func replaceBottomWithChamfer() {
        guard let node = activeFilletNode, let rounding = node.rounding else { return }
        let bottom = bottomEdges(of: node).filter { !rounding.chamfers[$0] && rounding.edges[$0] > 1 }
        updateFillet(node.id) { rounding in
            for e in bottom { rounding.chamfers[e] = true }
        }
        showToast("Bottom edges: 45° chamfer", undo: true)
    }

    func applyFilletPreset(_ preset: FilletPreset) {
        for id in roundableIDs {
            let r = doc.node(id)?.rounding?.radius ?? roundingRadius
            updateFillet(id) { rounding in
                rounding = BoxRounding()
                let round: [Int]
                switch preset {
                case .allEdges: round = Array(0..<12)
                case .topAndVertical, .print: round = BoxRounding.topEdges + BoxRounding.verticalEdges
                case .vertical: round = BoxRounding.verticalEdges
                case .top: round = BoxRounding.topEdges
                case .reset: round = []
                }
                for e in round { rounding.edges[e] = r }
                if preset == .print {
                    for e in BoxRounding.bottomEdges {
                        rounding.edges[e] = r
                        rounding.chamfers[e] = true
                    }
                }
            }
        }
    }

    func clearRounding() {
        applyFilletPreset(.reset)
    }

    private func updateFillet(_ id: UUID, _ body: (inout BoxRounding) -> Void) {
        mutate { document in
            document.update(id) { node in
                var rounding = node.rounding ?? BoxRounding()
                body(&rounding)
                node.rounding = rounding.isEmpty ? nil : rounding
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

    func toggleOutlineMode() {
        outlineMode.toggle()
        showToast(outlineMode ? "Outline mode: on" : "Outline mode: off")
    }

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
        showToast("New project", undo: true)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let loaded = try JSONDecoder().decode(SceneDocument.self, from: data)
                self.replaceDocument(loaded)
                self.projectURL = url
                self.showToast("Opened: \(url.lastPathComponent)", undo: true)
            } catch {
                self.showToast("Could not open: \(error.localizedDescription)")
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
        panel.title = "Save Project"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? "Project.json"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.projectURL = url
            self.write(to: url)
        }
    }

    private func write(to url: URL) {
        do {
            try Persistence.save(doc, to: url)
            showToast("Saved: \(url.lastPathComponent)")
        } catch {
            showToast("Could not save: \(error.localizedDescription)")
        }
    }

    func exportSTL() {
        // В файл идёт только точная геометрия: черновик или идущий расчёт дожидаемся.
        if isComputing || output.isDraft {
            exportWhenReady = true
            settle()
            showToast("Exporting after computing…")
            return
        }
        let meshes = doc.nodes
            .filter { $0.visible && $0.mode == .solid }
            .compactMap { node in output.meshes[node.id]?.transformed(by: node.pose) }
            .filter { $0.triangleCount > 0 }
        guard !meshes.isEmpty else {
            showToast("Nothing to export: no visible solids")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export STL"
        panel.allowedContentTypes = [UTType(filenameExtension: "stl") ?? .data]
        let base = projectURL?.deletingPathExtension().lastPathComponent ?? "model"
        panel.nameFieldStringValue = base + ".stl"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try STLWriter.binary(meshes).write(to: url, options: .atomic)
                self.showToast("Exported: \(url.lastPathComponent)")
            } catch {
                self.showToast("Could not export: \(error.localizedDescription)")
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
