//
//  GeometryKernel.swift
//  Вычисление дерева в треугольные меши. Работает в отдельном потоке
//  с большим стеком (BSP рекурсивен) и кэширует результаты узлов.
//
//  Меши хранятся в локальных координатах узла: положение применяется
//  при отрисовке матрицей. Поэтому перемещение детали не требует пересчёта.
//

import Foundation

/// Треугольники. 8 float на вершину: позиция (x, y, z, 0) и нормаль (x, y, z, 0) —
/// совпадает с раскладкой float3 в Metal.
nonisolated struct TriMesh: Sendable {
    var data: [Float] = []
    var bounds = AABB.empty

    static let floatsPerVertex = 8

    var vertexCount: Int { data.count / TriMesh.floatsPerVertex }
    var triangleCount: Int { vertexCount / 3 }

    init() {}

    init(polygons: [CSGPolygon]) {
        var estimate = 0
        for polygon in polygons {
            estimate += max(polygon.vertices.count - 2, 0) * 3 * TriMesh.floatsPerVertex
        }
        data.reserveCapacity(estimate)

        for polygon in polygons {
            let count = polygon.vertices.count
            guard count >= 3 else { continue }
            let planeNormal = polygon.plane.normal
            var normals: [Vec3] = []
            normals.reserveCapacity(count)
            for vertex in polygon.vertices {
                var n = vertex.normal
                let len = n.length
                if len < 1e-9 || n.dot(planeNormal) <= 0 {
                    n = planeNormal
                } else {
                    n = n / len
                }
                normals.append(n)
                bounds.include(vertex.pos)
            }
            let v = polygon.vertices
            for k in 1..<(count - 1) {
                append(v[0].pos, normals[0])
                append(v[k].pos, normals[k])
                append(v[k + 1].pos, normals[k + 1])
            }
        }
    }

    /// Копия в других координатах — для экспорта.
    func transformed(by pose: Pose) -> TriMesh {
        if pose.isIdentity { return self }
        var result = TriMesh()
        result.data.reserveCapacity(data.count)
        let stride = TriMesh.floatsPerVertex
        var i = 0
        while i + stride <= data.count {
            let p = pose.apply(Vec3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])))
            let n = pose.applyDir(Vec3(Double(data[i + 4]), Double(data[i + 5]), Double(data[i + 6])))
            result.append(p, n)
            result.bounds.include(p)
            i += stride
        }
        return result
    }

    private mutating func append(_ p: Vec3, _ n: Vec3) {
        data.append(Float(p.x))
        data.append(Float(p.y))
        data.append(Float(p.z))
        data.append(0)
        data.append(Float(n.x))
        data.append(Float(n.y))
        data.append(Float(n.z))
        data.append(0)
    }
}

nonisolated struct KernelOutput: Sendable {
    /// Меш каждого узла в его локальных координатах (без собственного положения
    /// и без учёта режима тело/отверстие).
    var meshes: [UUID: TriMesh] = [:]
    var generation: Int = 0
    var milliseconds: Double = 0
}

nonisolated final class GeometryKernel {
    private var polygonCache: [Node: [CSGPolygon]] = [:]
    private var nextPolygonCache: [Node: [CSGPolygon]] = [:]
    private var meshCache: [Node: TriMesh] = [:]
    private var nextMeshCache: [Node: TriMesh] = [:]

    func evaluate(_ document: SceneDocument) -> KernelOutput {
        let start = Date()
        nextPolygonCache = [:]
        nextMeshCache = [:]
        var output = KernelOutput()
        for node in document.nodes {
            visit(node, output: &output)
        }
        polygonCache = nextPolygonCache
        meshCache = nextMeshCache
        nextPolygonCache = [:]
        nextMeshCache = [:]
        output.milliseconds = Date().timeIntervalSince(start) * 1000
        return output
    }

    private func visit(_ node: Node, output: inout KernelOutput) {
        output.meshes[node.id] = localMesh(node)
        for child in node.children {
            visit(child, output: &output)
        }
    }

    private func localMesh(_ node: Node) -> TriMesh {
        let key = node.localKey
        if let hit = nextMeshCache[key] { return hit }
        let mesh = meshCache[key] ?? TriMesh(polygons: localPolygons(node))
        nextMeshCache[key] = mesh
        return mesh
    }

    /// Геометрия узла в его собственных координатах.
    private func localPolygons(_ node: Node) -> [CSGPolygon] {
        let key = node.localKey
        if let hit = nextPolygonCache[key] { return hit }
        if let hit = polygonCache[key] {
            nextPolygonCache[key] = hit
            return hit
        }

        let result: [CSGPolygon]
        if node.kind == .group {
            var solid: [CSGPolygon] = []
            var solidBox = AABB.empty
            var holes: [(polygons: [CSGPolygon], box: AABB)] = []
            for child in node.children where child.visible {
                let polygons = CSG.transformed(localPolygons(child), by: child.pose)
                guard !polygons.isEmpty else { continue }
                let box = CSG.bounds(of: polygons)
                if child.mode == .solid {
                    // Непересекающиеся тела объединяем простым сложением, без BSP.
                    if solid.isEmpty || !solidBox.intersects(box) {
                        solid.append(contentsOf: polygons)
                    } else {
                        solid = CSG.union(solid, polygons)
                    }
                    solidBox.formUnion(box)
                } else {
                    holes.append((polygons, box))
                }
            }
            for hole in holes where hole.box.intersects(solidBox) {
                solid = CSG.subtract(solid, hole.polygons)
            }
            result = solid
        } else {
            result = Tessellator.polygons(for: node)
        }

        nextPolygonCache[key] = result
        return result
    }
}

/// Фоновый поток вычислений. Если правки приходят быстрее, чем считается,
/// промежуточные версии пропускаются: считается только последняя.
nonisolated final class KernelWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: (document: SceneDocument, generation: Int)?
    private let kernel = GeometryKernel()
    private let deliver: @Sendable (KernelOutput) -> Void

    init(deliver: @escaping @Sendable (KernelOutput) -> Void) {
        self.deliver = deliver
        let thread = Thread { [unowned self] in
            self.loop()
        }
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInitiated
        thread.name = "GeometryKernel"
        thread.start()
    }

    func submit(_ document: SceneDocument, generation: Int) {
        condition.lock()
        pending = (document, generation)
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while pending == nil {
                condition.wait()
            }
            let job = pending!
            pending = nil
            condition.unlock()

            var output = kernel.evaluate(job.document)
            output.generation = job.generation
            deliver(output)
        }
    }
}
