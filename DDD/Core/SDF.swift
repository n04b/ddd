//
//  SDF.swift
//  Поле расстояний со знаком (SDF) для группы с плавными стыками.
//  Меньше нуля — внутри тела, больше — снаружи, ноль — поверхность.
//
//  Группа считается как в SDF Modeler: дети применяются по порядку, сверху вниз,
//  и каждый своей операцией вливается в то, что получилось из детей выше:
//  • тело — объединение, отверстие — вычитание, маска — пересечение;
//  • Push, Avoid, Emboss, Deboss, Shell — операции с величиной strength:
//    зазор, высота рельефа, глубина гравировки, толщина стенки.
//  Стык сглаживается на размер k группы: скругление — гладкий минимум Иниго Квилеса
//  (полином второй степени), фаска — плоскость под 45° с катетом k. Обе формулы
//  непрерывны везде, поэтому сетка не рвётся; цена — тела ближе k друг к другу
//  срастаются перемычкой, а на гранях заподлицо вдоль шва вырастает невысокий валик.
//
//  Поля примитивов точные. Скругления и фаски рёбер блока повторяют RoundedBox:
//  тот же блок, срезанный цилиндрами рёбер, плоскостями фасок, сферами «авто»-вершин
//  и плоскостями срезов вершин.
//
//  Вложенные группы тоже становятся полями, со своим размером стыков или с острыми.
//  Сетку из поля строит SDFMesher.
//

import Foundation

/// Значение поля и его градиент (нормаль поверхности, если точка на ней).
nonisolated struct FieldSample {
    var d: Double
    var g: Vec3

    var negated: FieldSample { FieldSample(d: -d, g: -g) }

    /// Поле, сдвинутое на s: s > 0 — тело тоньше на s, s < 0 — толще.
    func offset(_ s: Double) -> FieldSample { FieldSample(d: d + s, g: g) }
}

/// Точка в координатах группы → расстояние со знаком, мм, и градиент. Снаружи значение
/// почти не больше настоящего расстояния до поверхности: пустоты можно пропускать блоками.
typealias DistanceField = (Vec3) -> FieldSample

nonisolated struct CompiledField {
    var field: DistanceField
    /// Где может быть поверхность, в координатах группы.
    var bounds: AABB
    /// Сумма площадей примитивов, мм², — оценка числа ячеек сетки.
    var area: Double
    /// Самая мелкая деталь, мм: размеры стыков и скруглений, величины операций,
    /// половина толщины примитивов.
    var detail: Double
    /// Самый большой размер стыка, мм.
    var largestBlend: Double
}

/// Как ребёнок вливается в то, что получилось из детей выше.
nonisolated enum BlendOperation: Equatable {
    case union
    case subtract
    case intersect
    case push
    case avoid
    case emboss
    case deboss
    case shell

    init(_ node: Node) {
        switch node.effect {
        case .push: self = .push
        case .avoid: self = .avoid
        case .emboss: self = .emboss
        case .deboss: self = .deboss
        case .shell: self = .shell
        case nil:
            switch node.mode {
            case .solid: self = .union
            case .hole: self = .subtract
            case .mask: self = .intersect
            }
        }
    }

    /// Объект сам добавляет материал, даже если выше ничего нет.
    var startsScene: Bool { self == .union || self == .push || self == .avoid }
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
        let k = max(node.blend?.radius ?? 0, 0)
        let kind = node.blend?.kind ?? .fillet
        let children = node.children.filter(\.visible)
        // Детей много — далёкие считаются по габаритам, а не целиком.
        let bounded = children.count > 2

        var scene: CompiledField?
        for child in children {
            guard let part = compile(child, pose: pose * child.pose) else { continue }
            let operation = BlendOperation(child)
            let strength = child.effect == nil ? 0 : child.effectStrength
            guard let current = scene else {
                // Выше ничего нет: вычитать и пересекать не с чем.
                if operation.startsScene { scene = part }
                continue
            }
            scene = apply(operation, part, to: current, k: k, kind: kind, strength: strength, bounded: bounded)
        }
        return scene
    }

    /// Ребёнок part вливается в сцену операцией: поле, габариты и оценки сетки.
    private static func apply(_ operation: BlendOperation, _ part: CompiledField, to scene: CompiledField,
                              k: Double, kind: BlendKind, strength r: Double, bounded: Bool) -> CompiledField? {
        var result = scene
        result.area += part.area
        result.detail = min(scene.detail, part.detail)
        if k > 0 { result.detail = min(result.detail, k) }
        if r > 0 { result.detail = min(result.detail, r) }
        result.largestBlend = max(scene.largestBlend, part.largestBlend, k)

        // Операция влияет не дальше k + r от объекта: дальше хватает его габаритов.
        let a = bounded ? SDF.bounded(part, margin: 2 * k + r + 0.5) : part.field
        let b = scene.field
        let reach = k + r

        switch operation {
        case .union:
            result.bounds = scene.bounds.union(part.bounds).expanded(by: k)
            result.field = { p in smoothMin(a(p), b(p), k, kind) }
        case .subtract:
            // Отверстие, которое не достаёт до тел, ничего не меняет.
            guard part.bounds.intersects(scene.bounds, margin: k) else { return scene }
            result.field = { p in smoothMax(a(p).negated, b(p), k, kind) }
        case .intersect:
            result.bounds = scene.bounds.intersection(part.bounds)
            guard !result.bounds.isEmpty else { return nil }
            result.field = { p in smoothMax(a(p), b(p), k, kind) }
        case .push:
            // Из сцены вырезан объект с запасом r, сам объект — в вырезе.
            result.bounds = scene.bounds.union(part.bounds)
            result.field = { p in
                let sa = a(p)
                let cut = smoothMax(sa.offset(-r).negated, b(p), k, kind)
                return cut.d < sa.d ? cut : sa
            }
        case .avoid:
            // Из объекта вырезана сцена с запасом r, сцена — как была.
            result.bounds = scene.bounds.union(part.bounds)
            result.field = { p in
                let sb = b(p)
                let cut = smoothMax(sb.offset(-r).negated, a(p), k, kind)
                return cut.d < sb.d ? cut : sb
            }
        case .emboss:
            // Сцена плюс часть объекта, что не дальше r над её поверхностью.
            guard part.bounds.intersects(scene.bounds, margin: reach) else { return scene }
            result.bounds = scene.bounds.expanded(by: reach)
            result.field = { p in
                let sb = b(p)
                return smoothMin(sb, smoothMax(a(p), sb.offset(-r), k, kind), k, kind)
            }
        case .deboss:
            // Сцена минус часть объекта, что не глубже r под её поверхностью.
            guard part.bounds.intersects(scene.bounds, margin: k) else { return scene }
            result.field = { p in
                let sb = b(p)
                let engraved = smoothMax(sb.offset(r).negated, a(p), k, kind)
                return smoothMax(engraved.negated, sb, k, kind)
            }
        case .shell:
            // Внутри объекта — стенка сцены толщиной r от её поверхности внутрь.
            result.bounds = scene.bounds.intersection(part.bounds)
            guard !result.bounds.isEmpty else { return nil }
            let half = r / 2
            result.field = { p in
                let inner = b(p).offset(half)
                let wall = FieldSample(d: abs(inner.d) - half, g: inner.d < 0 ? -inner.g : inner.g)
                return smoothMax(a(p), wall, k, kind)
            }
        }
        return result
    }

    /// Далеко от габаритов части поле — расстояние до габаритов: оно не больше
    /// настоящего, положительно, а операции дальше margin на результат не влияют.
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

    // MARK: Сглаживание

    static let rootHalf = 0.5.squareRoot()
    static let rootThird = (1.0 / 3).squareRoot()

    /// Объединение со стыком размера k. Скругление — гладкий минимум: стык начинается
    /// там, где расстояния до тел различаются меньше чем на k, и в прямом углу
    /// уходит от ребра на k вдоль каждой грани. Фаска — плоскость a + b = k.
    static func smoothMin(_ a: FieldSample, _ b: FieldSample, _ k: Double, _ kind: BlendKind) -> FieldSample {
        let m = a.d < b.d ? a : b
        guard k > 0 else { return m }
        switch kind {
        case .fillet:
            let h = min(max(0.5 + 0.5 * (b.d - a.d) / k, 0), 1)
            guard h > 0, h < 1 else { return m }
            // Производная по h равна нулю, поэтому градиент — просто смесь градиентов.
            return FieldSample(d: b.d + (a.d - b.d) * h - k * h * (1 - h), g: b.g + (a.g - b.g) * h)
        case .chamfer:
            let d = (a.d + b.d - k) * rootHalf
            return d < m.d ? FieldSample(d: d, g: (a.g + b.g) * rootHalf) : m
        }
    }

    /// Пересечение со стыком размера k: max(a, b) = −min(−a, −b).
    static func smoothMax(_ a: FieldSample, _ b: FieldSample, _ k: Double, _ kind: BlendKind) -> FieldSample {
        smoothMin(a.negated, b.negated, k, kind).negated
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
