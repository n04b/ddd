//
//  ImageAssets.swift
//  Файлы референс-изображений и их чтение.
//
//  Картинки хранятся отдельно от документа, по хешу содержимого: история правок
//  и автосохранение не копируют мегабайты. В файл проекта картинки встраиваются,
//  чтобы проект открывался на другом компьютере.
//

import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

nonisolated enum ImageAssets {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("3d/references", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ключ — 64 шестнадцатеричных знака: путь из файла проекта не выйдет за папку хранилища.
    static func isValidKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy(\.isHexDigit)
    }

    static func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Кладёт картинку в хранилище; одинаковые файлы хранятся один раз.
    static func store(_ data: Data) throws -> String {
        let key = key(for: data)
        let url = directory.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return key
    }

    static func data(_ key: String) -> Data? {
        guard isValidKey(key) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(key))
    }

    /// Удаляет картинки, на которые документ не ссылается. Вызывается при запуске,
    /// когда истории правок ещё нет; в файлах проектов картинки встроены.
    static func collectGarbage(keeping keys: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !keys.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Копия документа со встроенными картинками — для файла проекта.
    /// missing — сколько картинок не нашлось в хранилище.
    static func embedding(_ document: SceneDocument) -> (document: SceneDocument, missing: Int) {
        var copy = document
        var missing = 0
        for index in copy.references.indices {
            copy.references[index].embedded = data(copy.references[index].asset)
            if copy.references[index].embedded == nil { missing += 1 }
        }
        return (copy, missing)
    }

    /// Достаёт встроенные картинки в хранилище. Ключ пересчитывается по содержимому,
    /// поэтому чужой ключ из файла ни на что не влияет.
    static func extracting(_ document: SceneDocument) -> SceneDocument {
        var copy = document
        for index in copy.references.indices {
            guard let data = copy.references[index].embedded, let key = try? store(data) else { continue }
            copy.references[index].asset = key
            copy.references[index].embedded = nil
        }
        return copy
    }
}

/// Чтение картинок: размер и DPI из метаданных, растр с учётом поворота из EXIF.
/// PDF рисуется со страницы 1; размер страницы в нём точный, поэтому и масштаб точный.
nonisolated enum ReferenceDecoder {
    struct Info {
        var width: Int
        var height: Int
        var dpi: Double
    }

    /// Длинная сторона текстуры: больше на видеокарту не грузим.
    static let maxSide = 8192
    /// С каким разрешением растрируется PDF.
    static let pdfDPI: Double = 200

    static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    static func inspect(_ data: Data) -> Info? {
        if isPDF(data) {
            return pdfPage(data).map(pdfInfo)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let turned = (5...8).contains(orientation)
        if turned { swap(&width, &height) }
        let key = turned ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth
        var dpi = (properties[key] as? NSNumber)?.doubleValue
            ?? (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
            ?? 72
        if !(dpi >= 1 && dpi <= 100_000) { dpi = 72 }
        return Info(width: width, height: height, dpi: dpi)
    }

    /// Растр с учётом ориентации, длинная сторона не больше maxSide.
    static func image(_ data: Data, maxSide: Int = maxSide) -> CGImage? {
        if isPDF(data) {
            return renderPDF(data, maxSide: maxSide)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: PDF

    private static func pdfPage(_ data: Data) -> CGPDFPage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        return document.page(at: 1)
    }

    /// Размер страницы в пунктах (1/72 дюйма) с учётом её поворота.
    private static func pageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let quarter = ((Int(page.rotationAngle) % 360) + 360) % 360
        return quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    private static func pdfInfo(_ page: CGPDFPage) -> Info {
        let size = pageSize(page)
        let inches = (width: max(Double(size.width) / 72, 1e-3), height: max(Double(size.height) / 72, 1e-3))
        let dpi = min(pdfDPI, Double(maxSide) / max(inches.width, inches.height))
        let width = max(Int((inches.width * dpi).rounded()), 1)
        let height = max(Int((inches.height * dpi).rounded()), 1)
        // DPI по фактической ширине в пикселях: ширина в мм совпадает со страницей точно.
        return Info(width: width, height: height, dpi: Double(width) / inches.width)
    }

    private static func renderPDF(_ data: Data, maxSide: Int) -> CGImage? {
        guard let page = pdfPage(data) else { return nil }
        let info = pdfInfo(page)
        let scale = min(1, Double(maxSide) / Double(max(info.width, info.height)))
        let width = max(Int(Double(info.width) * scale), 1)
        let height = max(Int(Double(info.height) * scale), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Страница PDF прозрачна; без белого фона чёрные линии пропали бы на тёмном вьюпорте.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let size = pageSize(page)
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
