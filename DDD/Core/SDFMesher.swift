//
//  SDFMesher.swift
//  Поле расстояний → треугольники методом Dual Contouring (Ju и др., 2002).
//
//  Габариты группы покрываются сеткой кубических ячеек с шагом h. В каждой ячейке,
//  через которую проходит поверхность, ставится одна вершина — точка, ближайшая
//  к касательным плоскостям там, где поверхность пересекает рёбра ячейки (QEF).
//  Поэтому острые рёбра и углы блоков остаются острыми, а не срезаются, как
//  у Marching Cubes. Каждое ребро сетки, на концах которого поле меняет знак,
//  даёт четырёхугольник из вершин четырёх ячеек вокруг этого ребра.
//
//  Пустоты пропускаются блоками 4×4×4 ячейки и группами 4×4×4 блока: если поле
//  в центре дальше от нуля, чем половина диагонали (с запасом), поверхности там нет.
//  Блоки считаются параллельно.
//

import Foundation

nonisolated enum SDFMesher {
    /// Сколько ячеек с поверхностью допускается: около двух треугольников на ячейку.
    static let cellBudget = 160_000.0
    static let draftCellBudget = 16_000.0
    /// Не больше ячеек во всей сетке — иначе растут таблицы блоков.
    static let gridBudget = 64_000_000.0
    /// Ячеек в блоке по каждой оси и блоков в группе блоков.
    static let block = 4
    /// Запас на то, что после скруглённых операций поле растёт быстрее расстояния.
    static let lipschitz = 2.0
    /// Изломы круче 20° затеняются плоско, мягче — гладко.
    static let creaseCos = cos(20.0 * Double.pi / 180)

    static func polygons(for group: Node, draft: Bool) -> [CSGPolygon] {
        guard let compiled = SDF.compile(group), !compiled.bounds.isEmpty else { return [] }
        // Сглаженные операции уводят поле от расстояния на долю размера стыка k
        // (гладкий максимум — до k/4 вверх). С запасом расширяем полосу вокруг
        // поверхности, иначе блок с поверхностью можно пропустить.
        return mesh(compiled.field, bounds: compiled.bounds, step: step(for: compiled, draft: draft),
                    slack: 0.75 * compiled.largestBlend)
    }

    /// Шаг сетки: треть самой мелкой детали, чтобы скругление легло дугой,
    /// но не мельче, чем позволяют бюджеты ячеек. Черновик — в 2,5 раза грубее.
    static func step(for compiled: CompiledField, draft: Bool) -> Double {
        var h = min(max(compiled.detail / 3, 0.15), 0.6)
        h = max(h, (compiled.area / cellBudget).squareRoot())
        if draft {
            h = max(h * 2.5, (compiled.area / draftCellBudget).squareRoot())
        }
        let size = compiled.bounds.size
        h = max(h, cbrt(size.x * size.y * size.z / gridBudget))
        return max(h, max(size.x, size.y, size.z) / 1024)
    }

    static func mesh(_ field: @escaping DistanceField, bounds: AABB, step: Double, slack: Double = 0) -> [CSGPolygon] {
        guard !bounds.isEmpty, step > 0, bounds.size.length.isFinite else { return [] }
        let grid = Grid(bounds: bounds, step: step)
        let blocks = findBlocks(field, grid, slack: slack)
        guard !blocks.isEmpty else { return [] }

        // 1. Вершины ячеек и рёбра со сменой знака — по блокам, параллельно.
        let parts = parallelMap(blocks.count) { index in
            var mesher = BlockMesher(field: field, grid: grid, block: blocks[index])
            return mesher.run()
        }

        // 2. Сквозная нумерация вершин.
        var slots = [Int32](repeating: -1, count: grid.blockCount)
        var bases = [Int](repeating: 0, count: parts.count)
        var allPositions: [Vec3] = []
        var total = 0
        for (index, part) in parts.enumerated() {
            slots[grid.blockIndex(blocks[index])] = Int32(index)
            bases[index] = total
            total += part.positions.count
        }
        allPositions.reserveCapacity(total)
        for part in parts {
            allPositions.append(contentsOf: part.positions)
        }
        let table = VertexTable(grid: grid, slots: slots, bases: bases, locals: parts.map { $0.local })
        let positions = allPositions

        // 3. Четырёхугольники вокруг рёбер со сменой знака — по два треугольника.
        let triangles = parallelMap(parts.count) { index -> [Int32] in
            var result: [Int32] = []
            result.reserveCapacity(parts[index].quads.count * 6)
            for quad in parts[index].quads {
                let i = Int(quad.i), j = Int(quad.j), k = Int(quad.k)
                // Ячейки по кругу так, что обход смотрит вдоль оси ребра (e_b × e_c = e_a).
                let ring: (Int?, Int?, Int?, Int?)
                switch quad.axis {
                case 0: ring = (table[i, j, k], table[i, j + 1, k], table[i, j + 1, k + 1], table[i, j, k + 1])
                case 1: ring = (table[i, j, k], table[i, j, k + 1], table[i + 1, j, k + 1], table[i + 1, j, k])
                default: ring = (table[i, j, k], table[i + 1, j, k], table[i + 1, j + 1, k], table[i, j + 1, k])
                }
                guard let a = ring.0, let b = ring.1, let c = ring.2, let d = ring.3 else { continue }
                if quad.flip {
                    split(a, d, c, b, quad.normal, positions, into: &result)
                } else {
                    split(a, b, c, d, quad.normal, positions, into: &result)
                }
            }
            return result
        }

        // 4. Нормаль вершины — сумма нормалей соседних треугольников с весом по площади:
        // гладко на скруглениях и на переходе скругления в плоскость.
        var sums = [Vec3](repeating: .zero, count: positions.count)
        for list in triangles {
            var t = 0
            while t + 2 < list.count {
                let a = Int(list[t]), b = Int(list[t + 1]), c = Int(list[t + 2])
                let n = (positions[b] - positions[a]).cross(positions[c] - positions[a])
                sums[a] = sums[a] + n
                sums[b] = sums[b] + n
                sums[c] = sums[c] + n
                t += 3
            }
        }
        let normals = sums.map { $0.length > 1e-12 ? $0.normalized : $0 }

        // 5. Полигоны. На изломах — нормаль грани.
        let polygons = parallelMap(triangles.count) { index -> [CSGPolygon] in
            let list = triangles[index]
            var result: [CSGPolygon] = []
            result.reserveCapacity(list.count / 3)
            var t = 0
            while t + 2 < list.count {
                if let polygon = triangle(Int(list[t]), Int(list[t + 1]), Int(list[t + 2]), positions, normals) {
                    result.append(polygon)
                }
                t += 3
            }
            return result
        }
        return polygons.flatMap { $0 }
    }

    // MARK: Пустоты

    /// Блоки, через которые может проходить поверхность.
    private static func findBlocks(_ field: DistanceField, _ grid: Grid, slack: Double) -> [BlockCoord] {
        let n = SDFMesher.block
        let sx = (grid.bx + n - 1) / n
        let sy = (grid.by + n - 1) / n
        let sz = (grid.bz + n - 1) / n
        let blockSpan = Double(n) * grid.h
        let superSpan = Double(n) * blockSpan
        let halfDiagonal = 0.5 * 3.0.squareRoot()

        func far(_ center: Vec3, span: Double) -> Bool {
            abs(field(center).d) > lipschitz * span * halfDiagonal + grid.h + slack
        }

        let lists = parallelMap(sx * sy * sz) { index -> [BlockCoord] in
            let si = index % sx
            let sj = index / sx % sy
            let sk = index / (sx * sy)
            let center = grid.origin + Vec3((Double(si) + 0.5) * superSpan,
                                            (Double(sj) + 0.5) * superSpan,
                                            (Double(sk) + 0.5) * superSpan)
            if far(center, span: superSpan) { return [] }
            var result: [BlockCoord] = []
            for bk in sk * n..<min(sk * n + n, grid.bz) {
                for bj in sj * n..<min(sj * n + n, grid.by) {
                    for bi in si * n..<min(si * n + n, grid.bx) {
                        let c = grid.origin + Vec3((Double(bi) + 0.5) * blockSpan,
                                                   (Double(bj) + 0.5) * blockSpan,
                                                   (Double(bk) + 0.5) * blockSpan)
                        if !far(c, span: blockSpan) {
                            result.append(BlockCoord(i: bi, j: bj, k: bk))
                        }
                    }
                }
            }
            return result
        }
        return lists.flatMap { $0 }
    }

    // MARK: Треугольники

    /// Четырёхугольник a-b-c-d делится по той диагонали, при которой оба треугольника
    /// ближе к нормали поверхности на ребре: так не появляются складки на изломах.
    /// Треугольники дописываются тройками номеров вершин.
    private static func split(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ normal: Vec3,
                              _ positions: [Vec3], into result: inout [Int32]) {
        let pa = positions[a], pb = positions[b], pc = positions[c], pd = positions[d]
        func agreement(_ n: Vec3) -> Double {
            let length = n.length
            return length < 1e-12 ? 1 : n.dot(normal) / length
        }
        let first = min(agreement((pb - pa).cross(pc - pa)), agreement((pc - pa).cross(pd - pa)))
        let second = min(agreement((pb - pa).cross(pd - pa)), agreement((pc - pb).cross(pd - pb)))
        if first >= second {
            result.append(contentsOf: [Int32(a), Int32(b), Int32(c), Int32(a), Int32(c), Int32(d)])
        } else {
            result.append(contentsOf: [Int32(a), Int32(b), Int32(d), Int32(b), Int32(c), Int32(d)])
        }
    }

    /// На изломах — нормаль грани, на гладких участках — нормаль поверхности.
    private static func triangle(_ a: Int, _ b: Int, _ c: Int,
                                 _ positions: [Vec3], _ normals: [Vec3]) -> CSGPolygon? {
        let pa = positions[a], pb = positions[b], pc = positions[c]
        guard let plane = CSGPlane.fromPoints([pa, pb, pc]) else { return nil }
        let face = plane.normal
        func shade(_ id: Int) -> Vec3 {
            let n = normals[id]
            return n.dot(face) >= creaseCos ? n : face
        }
        return CSGPolygon(vertices: [CSGVertex(pos: pa, normal: shade(a)),
                                     CSGVertex(pos: pb, normal: shade(b)),
                                     CSGVertex(pos: pc, normal: shade(c))], plane: plane)
    }

    // MARK: Параллельность

    /// Каждая итерация пишет только в свою ячейку результата.
    private static func parallelMap<T>(_ count: Int, _ body: (Int) -> T) -> [T] {
        guard count > 1 else { return count == 1 ? [body(0)] : [] }
        var results = [T?](repeating: nil, count: count)
        results.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let output = SharedOutput(base: base)
            DispatchQueue.concurrentPerform(iterations: count) { index in
                output.base[index] = body(index)
            }
        }
        return results.map { $0! }
    }
}

private nonisolated struct SharedOutput<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T?>
}

// MARK: - Сетка

private nonisolated struct BlockCoord {
    var i: Int
    var j: Int
    var k: Int
}

private nonisolated struct Grid {
    let origin: Vec3
    let h: Double
    /// Ячеек по осям.
    let nx, ny, nz: Int
    /// Блоков по осям.
    let bx, by, bz: Int

    init(bounds: AABB, step: Double) {
        h = step
        // Поверхность не подходит к краю сетки ближе двух ячеек: крайние углы снаружи.
        // Сдвиг на дробную долю шага, разный по осям: грани блоков с «круглыми» размерами
        // иначе ложатся точно на плоскости сетки, поле в углах ячеек равно нулю,
        // и соседние вершины слипаются в вырожденные треугольники.
        let pad = Vec3(2.37 * step, 2.41 * step, 2.43 * step)
        origin = bounds.lo - pad
        let size = bounds.size
        nx = max(Int(((size.x + 2 * pad.x) / step).rounded(.up)), 1)
        ny = max(Int(((size.y + 2 * pad.y) / step).rounded(.up)), 1)
        nz = max(Int(((size.z + 2 * pad.z) / step).rounded(.up)), 1)
        let n = SDFMesher.block
        bx = (nx + n - 1) / n
        by = (ny + n - 1) / n
        bz = (nz + n - 1) / n
    }

    var blockCount: Int { bx * by * bz }

    func blockIndex(_ b: BlockCoord) -> Int {
        b.i + bx * (b.j + by * b.k)
    }

    func corner(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
        Vec3(origin.x + Double(i) * h, origin.y + Double(j) * h, origin.z + Double(k) * h)
    }
}

/// Сквозной номер вершины ячейки: блок → его место в списке блоков → ячейка в блоке.
private nonisolated struct VertexTable {
    let grid: Grid
    /// Для каждого блока сетки — его номер в списке блоков с поверхностью, или −1.
    let slots: [Int32]
    /// Номер первой вершины каждого блока.
    let bases: [Int]
    let locals: [[Int32]]

    subscript(i: Int, j: Int, k: Int) -> Int? {
        guard i >= 0, j >= 0, k >= 0, i < grid.nx, j < grid.ny, k < grid.nz else { return nil }
        let n = SDFMesher.block
        let s = Int(slots[grid.blockIndex(BlockCoord(i: i / n, j: j / n, k: k / n))])
        guard s >= 0 else { return nil }
        let local = locals[s][i % n + n * (j % n + n * (k % n))]
        return local >= 0 ? bases[s] + Int(local) : nil
    }
}

// MARK: - Блок

private nonisolated struct Quad {
    /// Ячейка-владелец ребра: ребро идёт вдоль оси axis из её угла (+b, +c).
    var i: Int32
    var j: Int32
    var k: Int32
    var axis: Int8
    /// Знак меняется изнутри наружу против оси — обход в обратную сторону.
    var flip: Bool
    /// Нормаль поверхности там, где она пересекает ребро.
    var normal: Vec3
}

private nonisolated struct BlockPart {
    /// Номер вершины ячейки в блоке; −1 — поверхность через ячейку не проходит.
    var local = [Int32](repeating: -1, count: SDFMesher.block * SDFMesher.block * SDFMesher.block)
    var positions: [Vec3] = []
    var quads: [Quad] = []
}

private nonisolated struct BlockMesher {
    let field: DistanceField
    let grid: Grid
    /// Первая ячейка блока и число ячеек в нём по осям (у края сетки меньше четырёх).
    let i0, j0, k0: Int
    let ni, nj, nk: Int
    /// Углов по осям.
    let cx, cy, cz: Int
    var values: [Double] = []
    /// Пересечение поверхности с ребром: индекс по (ось, нижний угол), −1 — ещё не считали.
    var edgeSlot: [Int32] = []
    var crossings: [Vec3] = []
    var crossingNormals: [Vec3] = []

    init(field: @escaping DistanceField, grid: Grid, block: BlockCoord) {
        self.field = field
        self.grid = grid
        let n = SDFMesher.block
        i0 = block.i * n
        j0 = block.j * n
        k0 = block.k * n
        ni = min(n, grid.nx - i0)
        nj = min(n, grid.ny - j0)
        nk = min(n, grid.nz - k0)
        cx = ni + 1
        cy = nj + 1
        cz = nk + 1
    }

    private func index(_ i: Int, _ j: Int, _ k: Int) -> Int {
        i + cx * (j + cy * k)
    }

    mutating func run() -> BlockPart {
        var part = BlockPart()
        values = [Double](repeating: 0, count: cx * cy * cz)
        var inside = false
        var outside = false
        for k in 0..<cz {
            for j in 0..<cy {
                for i in 0..<cx {
                    let v = field(grid.corner(i0 + i, j0 + j, k0 + k)).d
                    values[index(i, j, k)] = v
                    if v < 0 { inside = true } else { outside = true }
                }
            }
        }
        guard inside && outside else { return part }
        edgeSlot = [Int32](repeating: -1, count: 3 * cx * cy * cz)

        let n = SDFMesher.block
        for k in 0..<nk {
            for j in 0..<nj {
                for i in 0..<ni {
                    var mask = 0
                    for c in 0..<8 where values[index(i + (c & 1), j + ((c >> 1) & 1), k + ((c >> 2) & 1))] < 0 {
                        mask |= 1 << c
                    }
                    if mask == 0 || mask == 255 { continue }

                    // Двенадцать рёбер ячейки: по четыре вдоль каждой оси.
                    var qef = QEF()
                    addEdge(0, i, j, k, to: &qef)
                    addEdge(0, i, j + 1, k, to: &qef)
                    addEdge(0, i, j, k + 1, to: &qef)
                    addEdge(0, i, j + 1, k + 1, to: &qef)
                    addEdge(1, i, j, k, to: &qef)
                    addEdge(1, i + 1, j, k, to: &qef)
                    addEdge(1, i, j, k + 1, to: &qef)
                    addEdge(1, i + 1, j, k + 1, to: &qef)
                    addEdge(2, i, j, k, to: &qef)
                    addEdge(2, i + 1, j, k, to: &qef)
                    addEdge(2, i, j + 1, k, to: &qef)
                    addEdge(2, i + 1, j + 1, k, to: &qef)
                    guard qef.count > 0 else { continue }

                    let lo = grid.corner(i0 + i, j0 + j, k0 + k)
                    let hi = lo + Vec3(grid.h, grid.h, grid.h)
                    let p = qef.solve()
                    part.local[i + n * (j + n * k)] = Int32(part.positions.count)
                    part.positions.append(Vec3(min(max(p.x, lo.x), hi.x),
                                               min(max(p.y, lo.y), hi.y),
                                               min(max(p.z, lo.z), hi.z)))

                    // Рёбра, которыми владеет ячейка: из её угла (+b, +c) вдоль оси,
                    // где (a, b, c) — оси по кругу: X → (Y, Z), Y → (Z, X), Z → (X, Y).
                    own(0, i, j + 1, k + 1, cell: (i, j, k), into: &part)
                    own(1, i + 1, j, k + 1, cell: (i, j, k), into: &part)
                    own(2, i + 1, j + 1, k, cell: (i, j, k), into: &part)
                }
            }
        }
        return part
    }

    private func own(_ axis: Int, _ i: Int, _ j: Int, _ k: Int, cell: (Int, Int, Int), into part: inout BlockPart) {
        let start = values[index(i, j, k)]
        let end = values[endIndex(axis, i, j, k)]
        guard (start < 0) != (end < 0) else { return }
        let slot = Int(edgeSlot[axis * cx * cy * cz + index(i, j, k)])
        part.quads.append(Quad(i: Int32(i0 + cell.0), j: Int32(j0 + cell.1), k: Int32(k0 + cell.2),
                               axis: Int8(axis), flip: start >= 0, normal: crossingNormals[slot]))
    }

    private func endIndex(_ axis: Int, _ i: Int, _ j: Int, _ k: Int) -> Int {
        index(i + (axis == 0 ? 1 : 0), j + (axis == 1 ? 1 : 0), k + (axis == 2 ? 1 : 0))
    }

    /// Ребро из угла (i, j, k) блока вдоль оси: если знак меняется — точка и нормаль в QEF.
    private mutating func addEdge(_ axis: Int, _ i: Int, _ j: Int, _ k: Int, to qef: inout QEF) {
        let d0 = values[index(i, j, k)]
        let d1 = values[endIndex(axis, i, j, k)]
        guard (d0 < 0) != (d1 < 0) else { return }
        let key = axis * cx * cy * cz + index(i, j, k)
        var slot = Int(edgeSlot[key])
        if slot < 0 {
            let p0 = grid.corner(i0 + i, j0 + j, k0 + k)
            var p1 = p0
            p1[axis] += grid.h
            let (p, g) = crossing(p0, d0, p1, d1)
            let length = g.length
            var normal = Vec3.zero
            if length > 1e-12 {
                normal = g / length
            } else {
                normal[axis] = d0 < 0 ? 1 : -1
            }
            crossings.append(p)
            crossingNormals.append(normal)
            slot = crossings.count - 1
            edgeSlot[key] = Int32(slot)
        }
        qef.add(crossings[slot], crossingNormals[slot])
    }

    /// Где поле на ребре равно нулю: линейная оценка и три шага regula falsi
    /// в варианте Illinois (неподвижный конец не застревает). Возвращает точку
    /// и градиент поля в ней — нормаль поверхности.
    private func crossing(_ p0: Vec3, _ d0: Double, _ p1: Vec3, _ d1: Double) -> (Vec3, Vec3) {
        var a = p0, da = d0, b = p1, db = d1
        var p = a.lerp(b, da / (da - db))
        var sample = field(p)
        var side = 0
        for _ in 0..<3 where abs(sample.d) > 1e-7 * grid.h {
            if (sample.d < 0) == (da < 0) {
                a = p
                da = sample.d
                if side == -1 { db *= 0.5 }
                side = -1
            } else {
                b = p
                db = sample.d
                if side == 1 { da *= 0.5 }
                side = 1
            }
            p = a.lerp(b, da / (da - db))
            sample = field(p)
        }
        return (p, sample.g)
    }
}

/// Квадратичная ошибка: сумма квадратов расстояний до касательных плоскостей.
/// Минимум ищется от средней точки пересечений через псевдообратную матрицу:
/// направления, вдоль которых нормали почти не различаются (плоскость, пологий изгиб),
/// отбрасываются, и вершина там остаётся у средней точки. Острые рёбра и углы —
/// направления с большим собственным значением — ставят вершину точно на излом.
private nonisolated struct QEF {
    /// Собственные значения меньше этой доли наибольшего не считаются изломом
    /// (у двух граней это угол между ними около 35°).
    static let truncation = 0.1

    var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, a22 = 0.0
    var bx = 0.0, by = 0.0, bz = 0.0
    var mass = Vec3.zero
    var count = 0

    mutating func add(_ p: Vec3, _ n: Vec3) {
        a00 += n.x * n.x
        a01 += n.x * n.y
        a02 += n.x * n.z
        a11 += n.y * n.y
        a12 += n.y * n.z
        a22 += n.z * n.z
        let d = n.dot(p)
        bx += n.x * d
        by += n.y * d
        bz += n.z * d
        mass = mass + p
        count += 1
    }

    func solve() -> Vec3 {
        let m = mass / Double(count)
        // AᵀA·δ = Aᵀb − AᵀA·m, вершина = m + δ.
        let r = Vec3(bx - (a00 * m.x + a01 * m.y + a02 * m.z),
                     by - (a01 * m.x + a11 * m.y + a12 * m.z),
                     bz - (a02 * m.x + a12 * m.y + a22 * m.z))
        let (values, vectors) = QEF.eigen(a00, a01, a02, a11, a12, a22)
        let largest = max(values.x, values.y, values.z)
        guard largest > 1e-12 else { return m }
        var delta = Vec3.zero
        for k in 0..<3 where values[k] > QEF.truncation * largest {
            let v = vectors[k]
            delta = delta + v * (v.dot(r) / values[k])
        }
        return m + delta
    }

    /// Собственные значения и векторы симметричной матрицы 3×3 методом Якоби.
    static func eigen(_ a00: Double, _ a01: Double, _ a02: Double,
                      _ a11: Double, _ a12: Double, _ a22: Double) -> (Vec3, [Vec3]) {
        var a = [a00, a01, a02, a01, a11, a12, a02, a12, a22]
        var v = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
        for _ in 0..<6 {
            for pair in 0..<3 {
                // Пары (0, 1), (0, 2), (1, 2).
                let p = pair == 2 ? 1 : 0
                let q = pair == 0 ? 1 : 2
                let apq = a[p * 3 + q]
                guard abs(apq) > 1e-15 else { continue }
                let theta = (a[q * 3 + q] - a[p * 3 + p]) / (2 * apq)
                let t = (theta < 0 ? -1.0 : 1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot()
                let s = t * c
                for k in 0..<3 {
                    let akp = a[k * 3 + p], akq = a[k * 3 + q]
                    a[k * 3 + p] = c * akp - s * akq
                    a[k * 3 + q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p * 3 + k], aqk = a[q * 3 + k]
                    a[p * 3 + k] = c * apk - s * aqk
                    a[q * 3 + k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k * 3 + p], vkq = v[k * 3 + q]
                    v[k * 3 + p] = c * vkp - s * vkq
                    v[k * 3 + q] = s * vkp + c * vkq
                }
            }
        }
        let values = Vec3(a[0], a[4], a[8])
        let vectors = (0..<3).map { k in Vec3(v[k], v[3 + k], v[6 + k]) }
        return (values, vectors)
    }
}
