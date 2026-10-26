//
//  RoundedBox.swift
//  Скругление рёбер и вершин параллелепипеда.
//
//  Скруглённый блок остаётся выпуклым, поэтому строится не булевыми операциями,
//  а отсечением блока плоскостями: хордами цилиндра вдоль каждого ребра и гранями
//  сферы в каждой вершине. Отсечение выпуклого тела плоскостью всегда даёт
//  замкнутое выпуклое тело — без щелей и вырожденных кусков.
//
//  Вершина без скруглённых рёбер выпуклой быть не может, поэтому скругление
//  вершины скругляет и три её ребра, а угол становится сферическим. Рёбра без
//  скругления вершины сходятся пересечением цилиндров, со складками.
//

import Foundation

nonisolated struct BoxRounding: Codable, Hashable, Sendable {
    /// Радиусы рёбер, мм: 0–3 вдоль X, 4–7 вдоль Y, 8–11 вдоль Z.
    /// Внутри оси бит 1 — знак младшей из двух других осей, бит 2 — старшей.
    var edges: [Double] = Array(repeating: 0, count: 12)
    /// Радиусы вершин, мм. Индекс — биты знаков: X = 1, Y = 2, Z = 4.
    var vertices: [Double] = Array(repeating: 0, count: 8)

    var isEmpty: Bool {
        edges.allSatisfy { $0 <= 0 } && vertices.allSatisfy { $0 <= 0 }
    }

    var roundedEdgeCount: Int { edges.filter { $0 > 0 }.count }
    var roundedVertexCount: Int { vertices.filter { $0 > 0 }.count }

    /// Радиус для поля в инспекторе: первый ненулевой.
    var radius: Double? {
        (edges + vertices).first { $0 > 0 }
    }

    // MARK: Топология

    static func otherAxes(_ axis: Int) -> (Int, Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }

    /// Знаки вершины по осям, ±1.
    static func vertexSigns(_ v: Int) -> Vec3 {
        Vec3(v & 1 != 0 ? 1 : -1, v & 2 != 0 ? 1 : -1, v & 4 != 0 ? 1 : -1)
    }

    /// Ось ребра и знаки по двум другим осям.
    static func edgeLayout(_ e: Int) -> (axis: Int, b: Int, c: Int, sb: Double, sc: Double) {
        let axis = e / 4
        let (b, c) = otherAxes(axis)
        return (axis, b, c, e & 1 != 0 ? 1 : -1, e & 2 != 0 ? 1 : -1)
    }

    static func edgeVertices(_ e: Int) -> (Int, Int) {
        let l = edgeLayout(e)
        var v = 0
        if l.sb > 0 { v |= 1 << l.b }
        if l.sc > 0 { v |= 1 << l.c }
        return (v, v | 1 << l.axis)
    }

    static func vertexEdges(_ v: Int) -> [Int] {
        (0..<3).map { axis in
            let (b, c) = otherAxes(axis)
            return axis * 4 + (v >> b & 1) + 2 * (v >> c & 1)
        }
    }

    // MARK: Названия

    /// Перед — к −Y (вид спереди), верх — +Z.
    static func edgeName(_ e: Int) -> String {
        let l = edgeLayout(e)
        var signs: [Int: Double] = [:]
        signs[l.b] = l.sb
        signs[l.c] = l.sc
        return words(signs)
    }

    static func vertexName(_ v: Int) -> String {
        let s = vertexSigns(v)
        return words([0: s.x, 1: s.y, 2: s.z])
    }

    private static func words(_ signs: [Int: Double]) -> String {
        let forms: [Int: (minus: String, plus: String)] = [2: ("bottom", "top"), 1: ("front", "back"), 0: ("left", "right")]
        let parts = [2, 1, 0].compactMap { axis -> String? in
            guard let s = signs[axis], let form = forms[axis] else { return nil }
            return s < 0 ? form.minus : form.plus
        }
        let text = parts.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Тесселяция

nonisolated enum RoundedBox {
    private enum Surface {
        case flat
        case cylinder(center: Vec3, axis: Int)
        case sphere(center: Vec3)
    }

    private struct Cut {
        var normal: Vec3
        var w: Double
        var surface: Surface
    }

    private struct Facet {
        var points: [Vec3]
        var normal: Vec3
        var surface: Surface
    }

    private static let eps = 1e-7

    /// Сегментов на четверть окружности: хорда около миллиметра.
    /// Черновик, пока тянут поле, — три сегмента: форма видна, считается мгновенно.
    static func quarterSegments(_ radius: Double, draft: Bool = false) -> Int {
        let n = min(max(Int((Double.pi / 2 * radius).rounded(.up)), 3), 12)
        return draft ? min(n, 3) : n
    }

    static func polygons(size: Vec3, rounding: BoxRounding, draft: Bool = false) -> [CSGPolygon] {
        let h = size * 0.5
        let minHalf = min(h.x, h.y, h.z)

        let vertexRadius = rounding.vertices.map { min(max($0, 0), minHalf) }
        var facets = boxFacets(h)

        for e in 0..<12 {
            let l = BoxRounding.edgeLayout(e)
            let (va, vb) = BoxRounding.edgeVertices(e)
            let r = min(max(rounding.edges[e], vertexRadius[va], vertexRadius[vb], 0), h[l.b], h[l.c])
            guard r > 1e-4 else { continue }
            var center = Vec3.zero
            center[l.b] = l.sb * (h[l.b] - r)
            center[l.c] = l.sc * (h[l.c] - r)
            let n = quarterSegments(r, draft: draft)
            var cuts: [Cut] = []
            for k in 0..<n {
                let mid = (Double(k) + 0.5) / Double(n) * Double.pi / 2
                let half = Double.pi / 4 / Double(n)
                var normal = Vec3.zero
                normal[l.b] = l.sb * cos(mid)
                normal[l.c] = l.sc * sin(mid)
                // Хорда отстоит от оси на r·cos(половины шага).
                cuts.append(Cut(normal: normal, w: normal.dot(center) + r * cos(half),
                                surface: .cylinder(center: center, axis: l.axis)))
            }
            for cut in cuts {
                clip(&facets, by: cut)
            }
        }

        for v in 0..<8 {
            let r = vertexRadius[v]
            guard r > 1e-4 else { continue }
            let s = BoxRounding.vertexSigns(v)
            let center = Vec3(s.x * (h.x - r), s.y * (h.y - r), s.z * (h.z - r))
            let n = quarterSegments(r, draft: draft)
            var cuts: [Cut] = []
            func point(_ i: Int, _ j: Int) -> Vec3 {
                let theta = Double(i) / Double(n) * Double.pi / 2
                let phi = Double(j) / Double(n) * Double.pi / 2
                return center + Vec3(s.x * sin(phi) * cos(theta), s.y * sin(phi) * sin(theta), s.z * cos(phi)) * r
            }
            for j in 0..<n {
                for i in 0..<n {
                    var triangles = [[point(i, j + 1), point(i + 1, j + 1), point(i, j)]]
                    if j > 0 {
                        triangles.append([point(i + 1, j), point(i, j), point(i + 1, j + 1)])
                    }
                    for t in triangles {
                        var normal = (t[1] - t[0]).cross(t[2] - t[0]).normalized
                        let centroid = (t[0] + t[1] + t[2]) / 3
                        if normal.dot(centroid - center) < 0 { normal = -normal }
                        cuts.append(Cut(normal: normal, w: normal.dot(t[0]), surface: .sphere(center: center)))
                    }
                }
            }
            // Грани сферы срезают только у своего угла: остальные грани не трогаем,
            // иначе сотни срезов проходят по всему телу.
            let margin = -0.25 * r
            let nearCorner = { (facet: Facet) in
                facet.points.contains { p in
                    s.x * (p.x - center.x) > margin && s.y * (p.y - center.y) > margin
                        && s.z * (p.z - center.z) > margin
                }
            }
            var local = facets.filter(nearCorner)
            let rest = facets.filter { !nearCorner($0) }
            for cut in cuts {
                clip(&local, by: cut)
            }
            facets = rest + local
        }

        return facets.compactMap { facet in
            let normals = facet.points.map { vertexNormal($0, facet) }
            return Tessellator.outward(facet.points, normals: normals)
        }
    }

    private static func boxFacets(_ h: Vec3) -> [Facet] {
        var result: [Facet] = []
        for axis in 0..<3 {
            let (b, c) = BoxRounding.otherAxes(axis)
            for sign in [-1.0, 1.0] {
                var normal = Vec3.zero
                normal[axis] = sign
                let corners: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
                var points = corners.map { cb, cc -> Vec3 in
                    var p = Vec3.zero
                    p[axis] = sign * h[axis]
                    p[b] = cb * h[b]
                    p[c] = cc * h[c]
                    return p
                }
                if (points[1] - points[0]).cross(points[2] - points[0]).dot(normal) < 0 {
                    points.reverse()
                }
                result.append(Facet(points: points, normal: normal, surface: .flat))
            }
        }
        return result
    }

    /// Оставляет часть тела под плоскостью и закрывает срез новой гранью.
    private static func clip(_ facets: inout [Facet], by cut: Cut) {
        let outside = facets.contains { facet in
            facet.points.contains { cut.normal.dot($0) - cut.w > eps }
        }
        guard outside else { return }

        var kept: [Facet] = []
        kept.reserveCapacity(facets.count + 1)
        var section: [Vec3] = []

        for facet in facets {
            let d = facet.points.map { cut.normal.dot($0) - cut.w }
            if d.allSatisfy({ $0 <= eps }) {
                kept.append(facet)
                for (k, p) in facet.points.enumerated() where d[k] >= -eps {
                    section.append(p)
                }
                continue
            }
            var points: [Vec3] = []
            let count = facet.points.count
            for k in 0..<count {
                let a = facet.points[k]
                let b = facet.points[(k + 1) % count]
                let da = d[k]
                let db = d[(k + 1) % count]
                if da <= eps {
                    points.append(a)
                    if da >= -eps { section.append(a) }
                }
                if (da < -eps && db > eps) || (da > eps && db < -eps) {
                    let p = intersection(a, da, b, db)
                    points.append(p)
                    section.append(p)
                }
            }
            points = deduplicated(points)
            if points.count >= 3 {
                kept.append(Facet(points: points, normal: facet.normal, surface: facet.surface))
            }
        }

        let cap = convexPolygon(deduplicated(section), normal: cut.normal)
        if cap.count >= 3 {
            kept.append(Facet(points: cap, normal: cut.normal, surface: cut.surface))
        }
        facets = kept
    }

    /// Точка пересечения считается в одном порядке концов, чтобы соседние грани
    /// получили бит-в-бит одинаковую вершину.
    private static func intersection(_ a: Vec3, _ da: Double, _ b: Vec3, _ db: Double) -> Vec3 {
        let swap = (a.x, a.y, a.z) > (b.x, b.y, b.z)
        let (p, dp, q, dq) = swap ? (b, db, a, da) : (a, da, b, db)
        return p.lerp(q, dp / (dp - dq))
    }

    private static func deduplicated(_ points: [Vec3]) -> [Vec3] {
        var result: [Vec3] = []
        for p in points where !result.contains(where: { ($0 - p).length < 1e-6 }) {
            result.append(p)
        }
        return result
    }

    /// Точки среза лежат на выпуклом контуре: упорядочиваем их по углу вокруг центра.
    private static func convexPolygon(_ points: [Vec3], normal: Vec3) -> [Vec3] {
        guard points.count >= 3 else { return [] }
        var center = Vec3.zero
        for p in points { center = center + p }
        center = center / Double(points.count)
        let helper = abs(normal.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let u = normal.cross(helper).normalized
        let v = normal.cross(u)
        return points.sorted { a, b in
            atan2((a - center).dot(v), (a - center).dot(u)) < atan2((b - center).dot(v), (b - center).dot(u))
        }
    }

    /// Нормаль исходной поверхности: грани скругления затеняются гладко,
    /// а на стыке с плоской гранью нормали совпадают.
    private static func vertexNormal(_ p: Vec3, _ facet: Facet) -> Vec3 {
        var n: Vec3
        switch facet.surface {
        case .flat:
            return facet.normal
        case let .cylinder(center, axis):
            n = p - center
            n[axis] = 0
        case let .sphere(center):
            n = p - center
        }
        guard n.length > 1e-9, n.dot(facet.normal) > 0 else { return facet.normal }
        return n.normalized
    }
}
