//
//  SDF.swift
//  Поле расстояний со знаком (SDF) для группы с плавными стыками.
//  Меньше нуля — внутри тела, больше — снаружи, ноль — поверхность.
//
//  Группа считается по тем же правилам, что и BSP-группа: тела объединяются,
//  отверстия вычитаются, маски пересекаются. Скруглённые версии этих операций
//  (формулы из библиотеки hg_sdf) дают на каждом стыке скругление радиусом r
//  или фаску с катетом r; на прямом угле — ровно дугу и ровно 45°.
//
//  Обычное скругление расстояний не отличает внутренний угол от двух граней
//  заподлицо: там тоже оба расстояния малы, и вдоль шва вырастает валик. Поэтому
//  стык проверяется в центре «катящегося шара» — точке в r от обоих тел рядом
//  с данной. Радиус полный везде, кроме трёх случаев, где стыка на самом деле нет:
//  • «открытость»: основание перпендикуляра из центра на одно тело должно быть
//    так же далеко от другого тела, как сам центр. В настоящем внутреннем углу это так,
//    у граней заподлицо основание лежит прямо на другом теле, а у зазора — дальше;
//  • грани строго лицом к лицу (узкий зазор между телами);
//  • основания должны лежать на настоящей поверхности, а не на внутренней грани
//    тел внахлёст, где поле — лишь оценка.
//  Центр шара один на весь стык, поэтому радиус не скачет поперёк скругления.
//
//  Поля примитивов точные. Скругления и фаски рёбер блока повторяют RoundedBox:
//  тот же блок, срезанный цилиндрами рёбер, плоскостями фасок, сферами «авто»-вершин
//  и плоскостями срезов вершин.
//
//  Вложенные группы тоже становятся полями, со своим радиусом или с острыми стыками.
//  Сетку из поля строит SDFMesher.
//

import Foundation

/// Значение поля и его градиент (нормаль поверхности, если точка на ней).
nonisolated struct FieldSample {
    var d: Double
    var g: Vec3

    var negated: FieldSample { FieldSample(d: -d, g: -g) }
}

/// Точка в координатах группы → расстояние со знаком, мм, и градиент. Снаружи значение
/// не больше настоящего расстояния до поверхности: пустоты можно пропускать блоками.
typealias DistanceField = (Vec3) -> FieldSample

nonisolated struct CompiledField {
    var field: DistanceField
    /// Где может быть поверхность, в координатах группы.
    var bounds: AABB
    /// Сумма площадей примитивов, мм², — оценка числа ячеек сетки.
    var area: Double
    /// Самая мелкая деталь, мм: радиусы стыков и скруглений, половина толщины примитивов.
    var detail: Double
    /// Самый большой радиус стыка, мм.
    var largestBlend: Double
}

nonisolated enum SDF {
    /// Поле группы в её собственных координатах, без её положения. nil — тел нет.
    static func compile(_ group: Node) -> CompiledField? {
        compile(group, pose: .identity)
    }

    /// pose: из координат узла в координаты группы, для которой строится поле.
    private static func compile(_ node: Node, pose: Pose) -> CompiledField? {
        node.kind == .group ? group(node, pose: pose) : primitive(node, pose: pose)
    }

    // MARK: Группа

    private static func group(_ node: Node, pose: Pose) -> CompiledField? {
        var solids: [CompiledField] = []
        var holes: [CompiledField] = []
        var masks: [CompiledField] = []
        for child in node.children where child.visible {
            guard let compiled = compile(child, pose: pose * child.pose) else { continue }
            switch child.mode {
            case .solid: solids.append(compiled)
            case .hole: holes.append(compiled)
            case .mask: masks.append(compiled)
            }
        }
        guard !solids.isEmpty else { return nil }

        let r = max(node.blend?.radius ?? 0, 0)
        let kind = node.blend?.kind ?? .fillet
        // Детей много — далёкие считаются по габаритам, а не целиком.
        let bounded = solids.count + holes.count + masks.count > 2

        var area = 0.0
        var detail = r > 0 ? r : Double.infinity
        var largest = r
        for part in solids + holes + masks {
            area += part.area
            detail = min(detail, part.detail)
            largest = max(largest, part.largestBlend)
        }

        // Скруглённое объединение добавляет материал не дальше r от стыка.
        var bounds = union(solids.map(\.bounds))
        if solids.count > 1 { bounds = bounds.expanded(by: r) }
        var field = combine(solids, r, kind, bounded: bounded)

        // Отверстие, которое не достаёт до тел, ничего не меняет.
        // Разность A − H = A ∩ ¬H = ¬(¬A ∪ H): стык считается тем же объединением.
        let cutting = holes.filter { $0.bounds.intersects(bounds, margin: r) }
        if !cutting.isEmpty {
            let solid = field
            let outside: DistanceField = { p in solid(p).negated }
            let hole = combine(cutting, r, kind, bounded: bounded)
            field = { p in blendUnion(outside, hole, r, kind, p).negated }
        }

        // Пересечение A ∩ M = ¬(¬A ∪ ¬M).
        if !masks.isEmpty {
            var maskBounds = union(masks.map(\.bounds))
            if masks.count > 1 { maskBounds = maskBounds.expanded(by: r) }
            bounds = bounds.intersection(maskBounds)
            guard !bounds.isEmpty else { return nil }
            let body = field
            let mask = combine(masks, r, kind, bounded: bounded)
            let outsideBody: DistanceField = { p in body(p).negated }
            let outsideMask: DistanceField = { p in mask(p).negated }
            field = { p in blendUnion(outsideBody, outsideMask, r, kind, p).negated }
        }

        return CompiledField(field: field, bounds: bounds, area: area, detail: detail, largestBlend: largest)
    }

    private static func union(_ boxes: [AABB]) -> AABB {
        var result = AABB.empty
        for box in boxes { result.formUnion(box) }
        return result
    }

    /// Объединяет поля частей: (((a ∪ b) ∪ c) ∪ d).
    private static func combine(_ parts: [CompiledField], _ r: Double, _ kind: BlendKind,
                                bounded: Bool) -> DistanceField {
        let fields = parts.map { bounded ? SDF.bounded($0, margin: 2 * r + 0.5) : $0.field }
        var result = fields[0]
        for next in fields.dropFirst() {
            let previous = result
            result = { p in blendUnion(previous, next, r, kind, p) }
        }
        return result
    }

    /// Далеко от габаритов части поле — расстояние до габаритов: оно не больше
    /// настоящего, положительно, а стыки дальше 2r на результат не влияют.
    private static func bounded(_ part: CompiledField, margin: Double) -> DistanceField {
        let field = part.field
        let lo = part.bounds.lo
        let hi = part.bounds.hi
        return { p in
            let dx = max(max(lo.x - p.x, p.x - hi.x), 0)
            let dy = max(max(lo.y - p.y, p.y - hi.y), 0)
            let dz = max(max(lo.z - p.z, p.z - hi.z), 0)
            let outside = (dx * dx + dy * dy + dz * dz).squareRoot()
            guard outside > margin else { return field(p) }
            let g = Vec3(p.x < lo.x ? -dx : dx, p.y < lo.y ? -dy : dy, p.z < lo.z ? -dz : dz) / outside
            return FieldSample(d: outside, g: g)
        }
    }

    // MARK: Операции

    static let rootHalf = 0.5.squareRoot()
    static let rootThird = (1.0 / 3).squareRoot()
    /// Фаска влияет, пока оба расстояния меньше r / (2 − √2).
    static let chamferReach = 1 / (2 - 2.0.squareRoot())

    /// Объединение полей a и b в точке p. Скругление — дуга радиуса r во внутреннем углу,
    /// фаска — 45° с катетом r. Пересечение и разность сводятся к нему через отрицание.
    static func blendUnion(_ a: DistanceField, _ b: DistanceField, _ r: Double, _ kind: BlendKind,
                           _ p: Vec3) -> FieldSample {
        let sa = a(p)
        let sb = b(p)
        let m = sa.d < sb.d ? sa : sb
        guard r > 0 else { return m }
        let reach = kind == .fillet ? r : r * chamferReach
        guard sa.d < reach, sb.d < reach else { return m }

        let re = r * joint(a, sa, b, sb, p, r)
        guard re > 1e-9 else { return m }

        switch kind {
        case .fillet:
            guard m.d < re else { return m }
            let ua = max(re - sa.d, 0)
            let ub = max(re - sb.d, 0)
            let length = (ua * ua + ub * ub).squareRoot()
            guard length > 1e-12 else { return m }
            return FieldSample(d: re - length, g: (sa.g * ua + sb.g * ub) / length)
        case .chamfer:
            let d = (sa.d + sb.d - re) * rootHalf
            return d < m.d ? FieldSample(d: d, g: (sa.g + sb.g) * rootHalf) : m
        }
    }

    /// Какая доля радиуса достаётся стыку рядом с точкой p: 1 — стык есть, 0 — стыка нет
    /// (грани заподлицо, зазор, внутренняя грань тел внахлёст).
    ///
    /// Множитель равен 1 для любого обычного угла между гранями и уходит в 0 только
    /// в этих трёх случаях. Промежуточные значения дали бы скачки там, где у тела
    /// сменяется ближайшая грань (на его рёбрах), — и зубцы в сетке.
    ///
    /// Проверки идут в центре шара: из p отходим от каждого тела до расстояния r.
    /// В прямом углу это одна точка для всей полосы скругления.
    static func joint(_ a: DistanceField, _ sa: FieldSample, _ b: DistanceField, _ sb: FieldSample,
                      _ p: Vec3, _ r: Double) -> Double {
        // Градиент вырожден там, где поле — лишь оценка (середина тел внахлёст).
        guard let na = unit(sa.g), let nb = unit(sb.g) else { return 0 }
        // Грани лицом к лицу через узкий зазор. Только почти точно параллельные:
        // более широкий порог задевает острые углы (ребро под наклоном к основанию)
        // и рвёт поле на их стыке с соседними скруглениями.
        var factor = ramp(-na.dot(nb), from: 0.995, to: 0.97)
        guard factor > 0 else { return 0 }

        let center = p + na * (r - sa.d) + nb * (r - sb.d)
        let ca = a(center)
        let cb = b(center)
        // Центр попал внутрь тела — шар здесь не катится, проверять нечего.
        guard ca.d > 0, cb.d > 0, let ua = unit(ca.g), let ub = unit(cb.g) else { return factor }

        // Основания перпендикуляров из центра должны лежать на настоящей поверхности.
        let footA = center - ua * ca.d
        let footB = center - ub * cb.d
        let miss = max(abs(a(footA).d) / ca.d, abs(b(footB).d) / cb.d)
        factor *= ramp(miss, from: 0.75, to: 0.25)
        guard factor > 0 else { return 0 }

        // Открытость: основание на одном теле так же далеко от другого, как центр.
        // У граней заподлицо отношение около 0, у зазора — около 2. Смысл оно имеет,
        // только когда шар помещается: иначе делим на малое расстояние.
        let fit = ramp(min(ca.d, cb.d) / r, from: 0.2, to: 0.8)
        if fit > 0 {
            let ratioA = max(b(footA).d, 0) / cb.d
            let ratioB = max(a(footB).d, 0) / ca.d
            let open = min(min(ramp(ratioA, from: 0.05, to: 0.5), ramp(ratioA, from: 1.95, to: 1.5)),
                           min(ramp(ratioB, from: 0.05, to: 0.5), ramp(ratioB, from: 1.95, to: 1.5)))
            factor *= 1 - fit * (1 - open)
        }
        return factor
    }

    private static func unit(_ v: Vec3) -> Vec3? {
        let length = v.length
        return length > 1e-12 ? v / length : nil
    }

    /// 0 при значении `from` и дальше от `to`, 1 при `to` и дальше от `from`, линейно между.
    private static func ramp(_ value: Double, from zero: Double, to one: Double) -> Double {
        min(max((value - zero) / (one - zero), 0), 1)
    }

    // MARK: Примитивы

    private static func primitive(_ node: Node, pose: Pose) -> CompiledField? {
        // Те же пределы размеров, что у Tessellator.
        let s = Vec3(max(node.size.x, 0.01), max(node.size.y, 0.01), max(node.size.z, 0.01))
        let frame = Frame(pose.inverse)
        let half: Vec3
        let local: (Double, Double, Double) -> FieldSample
        let area: Double
        var detail: Double

        switch node.kind {
        case .box:
            half = s * 0.5
            area = 2 * (s.x * s.y + s.y * s.z + s.z * s.x)
            detail = min(s.x, s.y, s.z) / 2
            if let rounding = node.rounding, !rounding.isEmpty {
                let shape = RoundedBoxField(size: s, rounding: rounding)
                detail = min(detail, shape.smallestRadius)
                local = { x, y, z in shape.sample(x, y, z) }
            } else {
                let h = half
                local = { x, y, z in box(x, y, z, h.x, h.y, h.z) }
            }
        case .sphere:
            let r = s.x / 2
            half = Vec3(r, r, r)
            area = 4 * Double.pi * r * r
            detail = r
            local = { x, y, z in sphere(x, y, z, r) }
        case .cylinder:
            let r = s.x / 2
            let hz = s.z / 2
            half = Vec3(r, r, hz)
            area = 2 * Double.pi * r * (s.z + r)
            detail = min(r, hz)
            local = { x, y, z in cylinder(x, y, z, r, hz) }
        case .group:
            return nil
        }

        let field: DistanceField = { p in
            let q = frame.apply(p)
            var sample = local(q.x, q.y, q.z)
            sample.g = frame.back(sample.g)
            return sample
        }
        let bounds = AABB(lo: -half, hi: half).transformed(by: pose)
        return CompiledField(field: field, bounds: bounds, area: area, detail: detail, largestBlend: 0)
    }

    /// Точное поле блока с полуразмерами h.
    static func box(_ x: Double, _ y: Double, _ z: Double, _ hx: Double, _ hy: Double, _ hz: Double) -> FieldSample {
        let sx = x < 0 ? -1.0 : 1.0
        let sy = y < 0 ? -1.0 : 1.0
        let sz = z < 0 ? -1.0 : 1.0
        let qx = abs(x) - hx
        let qy = abs(y) - hy
        let qz = abs(z) - hz
        if qx > 0 || qy > 0 || qz > 0 {
            let ox = max(qx, 0)
            let oy = max(qy, 0)
            let oz = max(qz, 0)
            let length = (ox * ox + oy * oy + oz * oz).squareRoot()
            return FieldSample(d: length, g: Vec3(sx * ox, sy * oy, sz * oz) / length)
        }
        if qx >= qy && qx >= qz { return FieldSample(d: qx, g: Vec3(sx, 0, 0)) }
        if qy >= qz { return FieldSample(d: qy, g: Vec3(0, sy, 0)) }
        return FieldSample(d: qz, g: Vec3(0, 0, sz))
    }

    static func sphere(_ x: Double, _ y: Double, _ z: Double, _ radius: Double) -> FieldSample {
        let length = (x * x + y * y + z * z).squareRoot()
        let g = length > 1e-12 ? Vec3(x, y, z) / length : Vec3(0, 0, 1)
        return FieldSample(d: length - radius, g: g)
    }

    /// Точное поле цилиндра вдоль Z.
    static func cylinder(_ x: Double, _ y: Double, _ z: Double, _ radius: Double, _ halfHeight: Double) -> FieldSample {
        let rho = (x * x + y * y).squareRoot()
        let radial = rho > 1e-12 ? Vec3(x / rho, y / rho, 0) : Vec3(1, 0, 0)
        let sz = z < 0 ? -1.0 : 1.0
        let dr = rho - radius
        let dz = abs(z) - halfHeight
        if dr > 0 || dz > 0 {
            let or = max(dr, 0)
            let oz = max(dz, 0)
            let length = (or * or + oz * oz).squareRoot()
            return FieldSample(d: length, g: (radial * or + Vec3(0, 0, sz * oz)) / length)
        }
        return dr > dz ? FieldSample(d: dr, g: radial) : FieldSample(d: dz, g: Vec3(0, 0, sz))
    }
}

/// Обратное положение примитива в виде двенадцати чисел: из координат группы в локальные.
nonisolated struct Frame {
    private let m00, m01, m02, m10, m11, m12, m20, m21, m22: Double
    private let tx, ty, tz: Double
    private let identity: Bool

    init(_ pose: Pose) {
        let r = pose.rotation
        m00 = r.r0.x; m01 = r.r0.y; m02 = r.r0.z
        m10 = r.r1.x; m11 = r.r1.y; m12 = r.r1.z
        m20 = r.r2.x; m21 = r.r2.y; m22 = r.r2.z
        tx = pose.translation.x
        ty = pose.translation.y
        tz = pose.translation.z
        identity = pose.isIdentity
    }

    @inline(__always)
    func apply(_ p: Vec3) -> Vec3 {
        if identity { return p }
        return Vec3(m00 * p.x + m01 * p.y + m02 * p.z + tx,
                    m10 * p.x + m11 * p.y + m12 * p.z + ty,
                    m20 * p.x + m21 * p.y + m22 * p.z + tz)
    }

    /// Градиент из локальных координат обратно в координаты группы (транспонированный поворот).
    @inline(__always)
    func back(_ g: Vec3) -> Vec3 {
        if identity { return g }
        return Vec3(m00 * g.x + m10 * g.y + m20 * g.z,
                    m01 * g.x + m11 * g.y + m21 * g.z,
                    m02 * g.x + m12 * g.y + m22 * g.z)
    }
}

/// Поле блока со скруглениями и фасками рёбер, «авто»-вершинами и срезами вершин.
/// Это пересечение выпуклых тел, как и в RoundedBox: максимум их полей точен внутри
/// и не больше настоящего расстояния снаружи.
nonisolated struct RoundedBoxField {
    /// Обработка ребра в плоскости двух других осей (u, v).
    private struct Edge {
        var su: Double
        var sv: Double
        /// Центр дуги скругления: su·u = cu, sv·v = cv.
        var cu: Double
        var cv: Double
        var r: Double
        var chamfer: Bool
        /// Фаска: su·u + sv·v ≤ w.
        var w: Double
    }

    /// Сфера «авто»-вершины: действует только в своём октанте.
    private struct Corner {
        var sx, sy, sz: Double
        var cx, cy, cz: Double
        var r: Double
    }

    /// Срез вершины: s·p ≤ w.
    private struct Cut {
        var sx, sy, sz: Double
        var w: Double
    }

    private let hx, hy, hz: Double
    /// Рёбра вдоль X: u = y, v = z. Вдоль Y: u = x, v = z. Вдоль Z: u = x, v = y.
    private let alongX: [Edge]
    private let alongY: [Edge]
    private let alongZ: [Edge]
    private let corners: [Corner]
    private let cuts: [Cut]
    let smallestRadius: Double

    init(size: Vec3, rounding: BoxRounding) {
        let h = size * 0.5
        hx = h.x
        hy = h.y
        hz = h.z
        let radii = rounding.effectiveEdges(size: size)

        var lists: [[Edge]] = [[], [], []]
        var smallest = Double.infinity
        for e in 0..<12 where radii[e] > 1e-4 {
            let r = radii[e]
            let l = BoxRounding.edgeLayout(e)
            lists[l.axis].append(Edge(su: l.sb, sv: l.sc, cu: h[l.b] - r, cv: h[l.c] - r, r: r,
                                      chamfer: rounding.chamfers[e], w: h[l.b] + h[l.c] - r))
            smallest = min(smallest, r)
        }
        alongX = lists[0]
        alongY = lists[1]
        alongZ = lists[2]

        var corners: [Corner] = []
        for v in 0..<8 {
            let edges = BoxRounding.vertexEdges(v)
            guard edges.allSatisfy({ radii[$0] > 1e-4 && !rounding.chamfers[$0] }) else { continue }
            let r = edges.map { radii[$0] }.min() ?? 0
            let s = BoxRounding.vertexSigns(v)
            corners.append(Corner(sx: s.x, sy: s.y, sz: s.z, cx: h.x - r, cy: h.y - r, cz: h.z - r, r: r))
        }
        self.corners = corners

        var cuts: [Cut] = []
        let maxCut = BoxRounding.maxCut(size: size)
        for v in 0..<8 {
            let d = min(max(rounding.cuts[v], 0), maxCut)
            guard d > 1e-4 else { continue }
            let s = BoxRounding.vertexSigns(v)
            cuts.append(Cut(sx: s.x, sy: s.y, sz: s.z, w: h.x + h.y + h.z - d))
            smallest = min(smallest, d)
        }
        self.cuts = cuts
        smallestRadius = smallest
    }

    func sample(_ x: Double, _ y: Double, _ z: Double) -> FieldSample {
        var s = SDF.box(x, y, z, hx, hy, hz)
        RoundedBoxField.edges(alongX, y, z, &s) { gu, gv in Vec3(0, gu, gv) }
        RoundedBoxField.edges(alongY, x, z, &s) { gu, gv in Vec3(gu, 0, gv) }
        RoundedBoxField.edges(alongZ, x, y, &s) { gu, gv in Vec3(gu, gv, 0) }
        for c in corners {
            let ax = c.sx * x - c.cx
            let ay = c.sy * y - c.cy
            let az = c.sz * z - c.cz
            guard ax > 0 && ay > 0 && az > 0 else { continue }
            let length = (ax * ax + ay * ay + az * az).squareRoot()
            if length - c.r > s.d {
                s = FieldSample(d: length - c.r, g: Vec3(c.sx * ax, c.sy * ay, c.sz * az) / length)
            }
        }
        for c in cuts {
            let d = (c.sx * x + c.sy * y + c.sz * z - c.w) * SDF.rootThird
            if d > s.d {
                s = FieldSample(d: d, g: Vec3(c.sx, c.sy, c.sz) * SDF.rootThird)
            }
        }
        return s
    }

    /// Скругление действует только в углу между касательными к дуге; соседние углы
    /// одной грани не пересекаются — их размеры уже поделены в effectiveEdges.
    private static func edges(_ list: [Edge], _ u: Double, _ v: Double, _ s: inout FieldSample,
                              _ axes: (Double, Double) -> Vec3) {
        for e in list {
            if e.chamfer {
                let d = (e.su * u + e.sv * v - e.w) * SDF.rootHalf
                if d > s.d {
                    s = FieldSample(d: d, g: axes(e.su * SDF.rootHalf, e.sv * SDF.rootHalf))
                }
            } else {
                let a = e.su * u - e.cu
                let b = e.sv * v - e.cv
                guard a > 0 && b > 0 else { continue }
                let length = (a * a + b * b).squareRoot()
                if length - e.r > s.d {
                    s = FieldSample(d: length - e.r, g: axes(e.su * a / length, e.sv * b / length))
                }
            }
        }
    }
}
