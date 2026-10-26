//
//  Scene.swift
//  Документ: дерево узлов. Примитивы — листья, группы — булевы операции:
//  результат группы = объединение тел минус объединение отверстий.
//

import Foundation

nonisolated enum NodeKind: String, Codable, Hashable, Sendable {
    case box
    case sphere
    case cylinder
    case group

    var baseName: String {
        switch self {
        case .box: return "Блок"
        case .sphere: return "Сфера"
        case .cylinder: return "Цилиндр"
        case .group: return "Группа"
        }
    }
}

nonisolated enum NodeMode: String, Codable, Hashable, Sendable {
    case solid
    case hole
}

nonisolated struct Node: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kind: NodeKind
    var mode: NodeMode = .solid
    var visible: Bool = true
    /// Центр объекта в пространстве родителя, мм.
    var position: Vec3 = .zero
    /// Углы Эйлера, градусы (X, затем Y, затем Z).
    var rotation: Vec3 = .zero
    /// Блок: X × Y × Z. Сфера: диаметр во всех трёх. Цилиндр: диаметр в X и Y, высота в Z.
    var size: Vec3 = Vec3(20, 20, 20)
    /// Скругление рёбер и вершин блока. nil — острые; в старых файлах поля нет.
    var rounding: BoxRounding?
    var children: [Node] = []

    static let nilID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var pose: Pose { Pose(position: position, rotationDegrees: rotation) }

    var summary: String {
        switch kind {
        case .box:
            let dims = "\(Fmt.number(size.x))×\(Fmt.number(size.y))×\(Fmt.number(size.z))"
            guard let r = rounding?.radius else { return dims }
            return dims + " R\(Fmt.number(r))"
        case .sphere: return "Ø\(Fmt.number(size.x))"
        case .cylinder: return "Ø\(Fmt.number(size.x))×\(Fmt.number(size.z))"
        case .group: return "\(children.count)"
        }
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

    init(nodes: [Node] = []) {
        self.nodes = nodes
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
        var body = Node(name: "Блок 1", kind: .box)
        body.size = Vec3(60, 40, 20)
        body.position = Vec3(0, 0, 10)

        var bore = Node(name: "Цилиндр 1", kind: .cylinder)
        bore.mode = .hole
        bore.size = Vec3(16, 16, 30)
        bore.position = Vec3(0, 0, 12)

        var cross = Node(name: "Цилиндр 2", kind: .cylinder)
        cross.mode = .hole
        cross.size = Vec3(8, 8, 70)
        cross.position = Vec3(0, 0, 10)
        cross.rotation = Vec3(0, 90, 0)

        var housing = Node(name: "Корпус", kind: .group)
        housing.children = [body, bore, cross]

        var ball = Node(name: "Сфера 1", kind: .sphere)
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
