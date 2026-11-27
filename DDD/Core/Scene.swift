//
//  Scene.swift
//  Документ: дерево узлов. Примитивы — листья, группы — булевы операции:
//  результат группы = (объединение тел − объединение отверстий) ∩ объединение масок.
//  Маска — 3D clipping mask: от содержимого группы остаётся только то, что внутри неё.
//

import Foundation

nonisolated enum NodeKind: String, Codable, Hashable, Sendable {
    case box
    case sphere
    case cylinder
    case group

    var baseName: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .group: return "Group"
        }
    }
}

nonisolated enum NodeMode: String, Codable, Hashable, Sendable {
    case solid
    case hole
    case mask
}

/// Операции SDF-группы сверх тела, отверстия и маски — как в SDF Modeler.
/// Действуют на то, что выше в списке группы; величина — strength объекта, мм.
nonisolated enum BlendEffect: String, Codable, Hashable, Sendable, CaseIterable {
    /// Объект вставляется с зазором: тела выше раздвигаются вокруг него на strength.
    case push
    /// Объект обходит тела выше, оставляя зазор strength.
    case avoid
    /// Поверхность тел выше поднимается на strength там, где её накрывает объект.
    case emboss
    /// Поверхность тел выше вдавливается на strength там, где её накрывает объект.
    case deboss
    /// Внутри объекта от тел выше остаётся стенка толщиной strength, снаружи — ничего.
    case shell

    static let defaultStrength = 1.0

    var title: String {
        switch self {
        case .push: return "Push"
        case .avoid: return "Avoid"
        case .emboss: return "Emboss"
        case .deboss: return "Deboss"
        case .shell: return "Shell"
        }
    }

    /// Режим, которым объект показывается и считается вне SDF-группы.
    var mode: NodeMode {
        switch self {
        case .push, .avoid, .emboss: return .solid
        case .deboss: return .hole
        case .shell: return .mask
        }
    }
}

/// Чем сопрягаются тела группы на стыках.
nonisolated enum BlendKind: String, Codable, Hashable, Sendable {
    case fillet
    case chamfer
}

/// Плавные стыки группы. Такая группа считается не BSP, а полем расстояний (SDF):
/// каждое ребро, которое дают её булевы операции, получает скругление или фаску.
nonisolated struct GroupBlend: Codable, Hashable, Sendable {
    /// Радиус скругления или катет фаски, мм.
    var radius: Double = 2
    var kind: BlendKind = .fillet

    static let minimumRadius = 0.1

    init(radius: Double = 2, kind: BlendKind = .fillet) {
        self.radius = radius
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case radius, kind
    }

    /// Недостающие поля — значения по умолчанию.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 2
        kind = try c.decodeIfPresent(BlendKind.self, forKey: .kind) ?? .fillet
    }
}

nonisolated struct Node: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: NodeKind
    var mode: NodeMode = .solid
    var visible: Bool = true
    /// Всегда рисовать объект и его потомков контуром, в любом режиме.
    /// nil — выключено; в старых файлах поля нет.
    var outlined: Bool?
    /// Центр объекта в пространстве родителя, мм.
    var position: Vec3 = .zero
    /// Углы Эйлера, градусы (X, затем Y, затем Z).
    var rotation: Vec3 = .zero
    /// Блок: X × Y × Z. Сфера: диаметр во всех трёх. Цилиндр: диаметр в X и Y, высота в Z.
    var size: Vec3 = Vec3(20, 20, 20)
    /// Скругление рёбер и вершин блока. nil — острые; в старых файлах поля нет.
    var rounding: BoxRounding?
    /// Плавные стыки детей группы (SDF). nil — острые стыки.
    var blend: GroupBlend?
    /// Операция в SDF-группе сверх режима (Push, Avoid, ...). nil — по режиму: тело, отверстие, маска.
    var effect: BlendEffect?
    /// Зазор, высота, глубина или толщина стенки операции, мм. nil — по умолчанию.
    var strength: Double?
    var children: [Node] = []

    static let nilID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var pose: Pose { Pose(position: position, rotationDegrees: rotation) }

    var summary: String {
        guard let effect else { return shapeSummary }
        return shapeSummary + " · " + effect.title + " " + Fmt.number(effectStrength)
    }

    private var shapeSummary: String {
        switch kind {
        case .box:
            let dims = "\(Fmt.number(size.x))×\(Fmt.number(size.y))×\(Fmt.number(size.z))"
            guard let r = rounding?.radius else { return dims }
            return dims + " · R\(Fmt.number(r))"
        case .sphere: return "Ø\(Fmt.number(size.x))"
        case .cylinder: return "Ø\(Fmt.number(size.x))×\(Fmt.number(size.z))"
        case .group:
            guard let blend else { return "\(children.count)" }
            return "\(children.count) · " + (blend.kind == .fillet ? "R" : "◢") + Fmt.number(blend.radius)
        }
    }

    /// Величина операции, мм.
    var effectStrength: Double { max(strength ?? BlendEffect.defaultStrength, 0) }

    /// Группа считается полем расстояний: со скруглениями или фасками на стыках,
    /// или если кто-то из детей задаёт операцию Push, Avoid, ... (тогда стыки острые).
    var isBlended: Bool {
        kind == .group && (blend != nil || children.contains { $0.visible && $0.effect != nil })
    }

    func withNewIDs() -> Node {
        var copy = self
        copy.id = UUID()
        copy.children = children.map { $0.withNewIDs() }
        return copy
    }

    /// Ключ кэша геометрии: без id и имён, чтобы переименование не пересчитывало CSG.
    var identityStripped: Node {
        var key = self
        key.id = Node.nilID
        key.name = ""
        key.outlined = nil
        key.children = children.map { $0.identityStripped }
        return key
    }

    /// Ключ локальной геометрии узла: без собственного положения, режима и видимости.
    /// Перемещение объекта верхнего уровня тогда не пересчитывает CSG, только переносит меш.
    var localKey: Node {
        var key = identityStripped
        key.position = .zero
        key.rotation = .zero
        key.mode = .solid
        key.visible = true
        return key
    }
}

nonisolated struct SceneDocument: Codable, Hashable, Sendable {
    var version: Int = 1
    var nodes: [Node] = []
    /// Референс-изображения: подложки для построения, в деталь не входят.
    var references: [ReferenceImage] = []

    init(nodes: [Node] = [], references: [ReferenceImage] = []) {
        self.nodes = nodes
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case version, nodes, references
    }

    /// В старых файлах нет референсов.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        nodes = try c.decode([Node].self, forKey: .nodes)
        references = try c.decodeIfPresent([ReferenceImage].self, forKey: .references) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(nodes, forKey: .nodes)
        if !references.isEmpty {
            try c.encode(references, forKey: .references)
        }
    }

    // MARK: Референсы

    func reference(_ id: UUID) -> ReferenceImage? {
        references.first { $0.id == id }
    }

    mutating func updateReference(_ id: UUID, _ body: (inout ReferenceImage) -> Void) {
        guard let index = references.firstIndex(where: { $0.id == id }) else { return }
        body(&references[index])
    }

    // MARK: Поиск

    func path(of id: UUID) -> [Int]? {
        SceneDocument.find(id, in: nodes, prefix: [])
    }

    func node(_ id: UUID) -> Node? {
        guard let p = path(of: id) else { return nil }
        return node(at: p)
    }

    func node(at path: [Int]) -> Node {
        var current = nodes[path[0]]
        for index in path.dropFirst() {
            current = current.children[index]
        }
        return current
    }

    func parentID(of id: UUID) -> UUID? {
        guard let p = path(of: id), p.count > 1 else { return nil }
        return node(at: Array(p.dropLast())).id
    }

    func indexInParent(_ id: UUID) -> Int? {
        path(of: id)?.last
    }

    func children(of parent: UUID?) -> [Node] {
        guard let parent else { return nodes }
        return node(parent)?.children ?? []
    }

    /// Предки от корня к родителю.
    func ancestors(of id: UUID) -> [UUID] {
        guard let p = path(of: id), p.count > 1 else { return [] }
        var result: [UUID] = []
        for k in 1..<p.count {
            result.append(node(at: Array(p.prefix(k))).id)
        }
        return result
    }

    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        ancestors(of: id).contains(ancestor)
    }

    /// Мировое положение узла, включая его собственное.
    func worldPose(of id: UUID) -> Pose {
        guard let p = path(of: id) else { return .identity }
        var pose = Pose.identity
        for k in 1...p.count {
            pose = pose * node(at: Array(p.prefix(k))).pose
        }
        return pose
    }

    func parentWorldPose(of id: UUID) -> Pose {
        guard let parent = parentID(of: id) else { return .identity }
        return worldPose(of: parent)
    }

    func allNodes() -> [Node] {
        var result: [Node] = []
        SceneDocument.flatten(nodes, into: &result)
        return result
    }

    // MARK: Изменения

    mutating func update(_ id: UUID, _ body: (inout Node) -> Void) {
        guard let p = path(of: id) else { return }
        SceneDocument.modify(&nodes, p[...], body)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Node? {
        guard let p = path(of: id) else { return nil }
        if p.count == 1 {
            return nodes.remove(at: p[0])
        }
        let last = p[p.count - 1]
        var removed: Node?
        SceneDocument.modify(&nodes, p.dropLast()) { parent in
            removed = parent.children.remove(at: last)
        }
        return removed
    }

    mutating func insert(_ node: Node, into parent: UUID?, at index: Int?) {
        if let parent, let p = path(of: parent) {
            SceneDocument.modify(&nodes, p[...]) { group in
                let i = Swift.min(Swift.max(index ?? group.children.count, 0), group.children.count)
                group.children.insert(node, at: i)
            }
        } else {
            let i = Swift.min(Swift.max(index ?? nodes.count, 0), nodes.count)
            nodes.insert(node, at: i)
        }
    }

    // MARK: Внутреннее

    private static func find(_ id: UUID, in list: [Node], prefix: [Int]) -> [Int]? {
        for (i, n) in list.enumerated() {
            if n.id == id { return prefix + [i] }
            if !n.children.isEmpty, let p = find(id, in: n.children, prefix: prefix + [i]) {
                return p
            }
        }
        return nil
    }

    private static func modify(_ list: inout [Node], _ path: ArraySlice<Int>, _ body: (inout Node) -> Void) {
        guard let i = path.first else { return }
        if path.count == 1 {
            body(&list[i])
        } else {
            modify(&list[i].children, path.dropFirst(), body)
        }
    }

    private static func flatten(_ list: [Node], into result: inout [Node]) {
        for n in list {
            result.append(n)
            flatten(n.children, into: &result)
        }
    }

    // MARK: Пример

    static func demo() -> SceneDocument {
        var body = Node(name: "Box 1", kind: .box)
        body.size = Vec3(60, 40, 20)
        body.position = Vec3(0, 0, 10)

        var bore = Node(name: "Cylinder 1", kind: .cylinder)
        bore.mode = .hole
        bore.size = Vec3(16, 16, 30)
        bore.position = Vec3(0, 0, 12)

        var cross = Node(name: "Cylinder 2", kind: .cylinder)
        cross.mode = .hole
        cross.size = Vec3(8, 8, 70)
        cross.position = Vec3(0, 0, 10)
        cross.rotation = Vec3(0, 90, 0)

        var housing = Node(name: "Housing", kind: .group)
        housing.children = [body, bore, cross]

        var ball = Node(name: "Sphere 1", kind: .sphere)
        ball.size = Vec3(24, 24, 24)
        ball.position = Vec3(58, 0, 12)

        return SceneDocument(nodes: [housing, ball])
    }
}

/// Форматирование чисел для интерфейса: без лишних нулей, точка как разделитель.
nonisolated enum Fmt {
    static func number(_ value: Double) -> String {
        let r = (value * 100).rounded() / 100
        if r == r.rounded(), abs(r) < 1e12 {
            return String(Int(r))
        }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
