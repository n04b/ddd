//
//  Reference.swift
//  Референс-изображение: картинка на плоскости, по которой строят форму.
//  В модель она не входит: ядро, выбор тел лучом и экспорт STL её не видят.
//
//  Картинка лежит в одной из плоскостей — сверху (XY), спереди (XZ) или справа (YZ),
//  может быть повёрнута в своей плоскости и отражена. Масштаб задан в DPI:
//  сколько пикселей картинки приходится на дюйм. Точки разметки хранятся
//  в пикселях и поэтому двигаются и масштабируются вместе с картинкой.
//

import Foundation

nonisolated enum ReferencePlane: String, Codable, Hashable, Sendable, CaseIterable {
    case top
    case front
    case right

    var title: String {
        switch self {
        case .top: return "Top"
        case .front: return "Front"
        case .right: return "Right"
        }
    }

    /// Оси плоскости до поворота: вправо, вверх и нормаль к зрителю — как на видах 2, 3 и 4.
    var basis: (right: Vec3, up: Vec3, normal: Vec3) {
        switch self {
        case .top: return (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))
        case .front: return (Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, -1, 0))
        case .right: return (Vec3(0, 1, 0), Vec3(0, 0, 1), Vec3(1, 0, 0))
        }
    }

    /// Мировые оси, вдоль которых лежит плоскость: их координаты у точек и меняются.
    var inPlaneAxes: (Int, Int) {
        switch self {
        case .top: return (0, 1)
        case .front: return (0, 2)
        case .right: return (1, 2)
        }
    }
}

/// Точка на картинке в пикселях: от левого верхнего угла, y вниз.
nonisolated struct Point2: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: Point2) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

/// Точка разметки: метка и место на картинке в пикселях.
nonisolated struct ReferenceMarker: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var label: String
    var x: Double
    var y: Double

    var point: Point2 {
        get { Point2(x, y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }
}

nonisolated struct ReferenceImage: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// Ключ файла в хранилище картинок — SHA-256 содержимого.
    var asset: String
    /// Размер картинки с учётом поворота из EXIF.
    var pixelWidth: Int
    var pixelHeight: Int
    /// DPI из файла; если его там нет — 72, как принято.
    var fileDPI: Double
    /// Текущий масштаб: пикселей на дюйм.
    var dpi: Double
    var plane: ReferencePlane = .top
    /// Центр картинки в мире, мм.
    var center: Vec3 = .zero
    /// Поворот в своей плоскости против часовой стрелки, если смотреть с лицевой стороны, градусы.
    var angle: Double = 0
    /// Отражение слева направо.
    var flipped = false
    var opacity: Double = 0.75
    var visible = true
    /// Мышью во вьюпорте не двигается.
    var locked = false
    /// Рисуется поверх модели: так её контур видно сквозь тела.
    var onTop = false
    var markers: [ReferenceMarker] = []
    /// Байты картинки. Есть только в сохранённом файле проекта, чтобы он открывался
    /// на другом компьютере; в памяти картинка лежит в хранилище, а здесь nil.
    var embedded: Data?

    init(name: String, asset: String, pixelWidth: Int, pixelHeight: Int, fileDPI: Double) {
        self.name = name
        self.asset = asset
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileDPI = fileDPI
        self.dpi = fileDPI
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, asset, pixelWidth, pixelHeight, fileDPI, dpi, plane, center, angle
        case flipped, opacity, visible, locked, onTop, markers, embedded
    }

    /// Необязательные поля читаются со значениями по умолчанию: новые поля не ломают старые файлы.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Reference"
        asset = try c.decode(String.self, forKey: .asset)
        pixelWidth = max(try c.decode(Int.self, forKey: .pixelWidth), 1)
        pixelHeight = max(try c.decode(Int.self, forKey: .pixelHeight), 1)
        fileDPI = try c.decodeIfPresent(Double.self, forKey: .fileDPI) ?? 72
        dpi = try c.decodeIfPresent(Double.self, forKey: .dpi) ?? fileDPI
        plane = try c.decodeIfPresent(ReferencePlane.self, forKey: .plane) ?? .top
        center = try c.decodeIfPresent(Vec3.self, forKey: .center) ?? .zero
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.75
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        onTop = try c.decodeIfPresent(Bool.self, forKey: .onTop) ?? false
        markers = try c.decodeIfPresent([ReferenceMarker].self, forKey: .markers) ?? []
        embedded = try c.decodeIfPresent(Data.self, forKey: .embedded)
    }
}

// MARK: - Геометрия

extension ReferenceImage {
    var mmPerPixel: Double { 25.4 / max(dpi, 1e-6) }
    /// Ширина и высота в мире, мм.
    var width: Double { Double(pixelWidth) * mmPerPixel }
    var height: Double { Double(pixelHeight) * mmPerPixel }

    /// Оси картинки в мире: вправо — куда растёт x пикселя, вверх — против роста y,
    /// нормаль — к лицевой стороне.
    var axes: (right: Vec3, up: Vec3, normal: Vec3) {
        let b = plane.basis
        let a = angle * .pi / 180
        let c = cos(a)
        let s = sin(a)
        var right = b.right * c + b.up * s
        let up = b.up * c - b.right * s
        if flipped { right = -right }
        return (right, up, b.normal)
    }

    /// Пиксель → точка в мире.
    func world(_ p: Point2) -> Vec3 {
        let ax = axes
        let s = mmPerPixel
        return center
            + ax.right * ((p.x - Double(pixelWidth) / 2) * s)
            + ax.up * ((Double(pixelHeight) / 2 - p.y) * s)
    }

    /// Точка в мире → пиксель (точка проецируется на плоскость картинки).
    func pixel(_ point: Vec3) -> Point2 {
        let ax = axes
        let d = point - center
        let s = mmPerPixel
        return Point2(d.dot(ax.right) / s + Double(pixelWidth) / 2,
                      Double(pixelHeight) / 2 - d.dot(ax.up) / s)
    }

    func contains(_ p: Point2) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= Double(pixelWidth) && p.y <= Double(pixelHeight)
    }

    func clamped(_ p: Point2) -> Point2 {
        Point2(min(max(p.x, 0), Double(pixelWidth)), min(max(p.y, 0), Double(pixelHeight)))
    }

    /// Пересечение луча с плоскостью картинки — без учёта её границ.
    func planeHit(_ ray: Ray) -> (t: Double, point: Vec3, pixel: Point2)? {
        let n = axes.normal
        let denom = ray.dir.dot(n)
        guard abs(denom) > 1e-6 else { return nil }
        let t = (center - ray.origin).dot(n) / denom
        guard t > 0 else { return nil }
        let point = ray.origin + ray.dir * t
        return (t, point, pixel(point))
    }

    /// Углы в мире: левый верхний, правый верхний, правый нижний, левый нижний.
    var corners: [Vec3] {
        let w = Double(pixelWidth)
        let h = Double(pixelHeight)
        return [Point2(0, 0), Point2(w, 0), Point2(w, h), Point2(0, h)].map(world)
    }

    var bounds: AABB {
        var box = AABB.empty
        for corner in corners { box.include(corner) }
        return box
    }

    /// Половина габарита по Z: у картинки, стоящей на столе, на этой высоте центр.
    var halfHeightZ: Double {
        let ax = axes
        return (abs(ax.right.z) * width + abs(ax.up.z) * height) / 2
    }

    /// Нижний край в мире.
    var bottomZ: Double { center.z - halfHeightZ }

    /// Место по умолчанию: сверху — центр в начале координат, спереди и справа — стоит на столе.
    var defaultCenter: Vec3 { Vec3(0, 0, Vec3.clean(halfHeightZ)) }

    /// Следующая свободная метка: A…Z, потом AA, AB…
    func nextMarkerLabel() -> String {
        let used = Set(markers.map(\.label))
        var index = 0
        while used.contains(ReferenceImage.label(index)) { index += 1 }
        return ReferenceImage.label(index)
    }

    static func label(_ index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            result = String(Character(Unicode.Scalar(UInt8(65 + n % 26)))) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }
}
