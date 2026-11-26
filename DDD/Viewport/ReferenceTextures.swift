//
//  ReferenceTextures.swift
//  Текстуры референс-изображений. Картинка читается и грузится на видеокарту
//  в фоне: пока текстуры нет, картинку просто не рисуем, а потом перерисовываем.
//

import Foundation
import Metal
import CoreGraphics

@MainActor
final class ReferenceTextures {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var cache: [String: MTLTexture] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    /// Текстура готова — нужна перерисовка.
    var onLoad: (() -> Void)?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    func texture(_ asset: String) -> MTLTexture? {
        if let texture = cache[asset] { return texture }
        guard !loading.contains(asset), !failed.contains(asset) else { return nil }
        loading.insert(asset)
        let device = self.device
        let queue = self.queue
        Task.detached(priority: .userInitiated) { [weak self] in
            let texture = ReferenceTextureLoader.texture(asset: asset, device: device, queue: queue)
            await self?.finish(asset, texture)
        }
        return nil
    }

    /// Отпускает текстуры картинок, которых в документе больше нет.
    func keep(only assets: Set<String>) {
        for key in cache.keys where !assets.contains(key) {
            cache[key] = nil
        }
        failed.formIntersection(assets)
    }

    private func finish(_ asset: String, _ texture: MTLTexture?) {
        loading.remove(asset)
        if let texture {
            cache[asset] = texture
        } else {
            failed.insert(asset)
        }
        onLoad?()
    }
}

nonisolated enum ReferenceTextureLoader {
    /// RGBA8 с premultiplied alpha и mip-уровнями: картинка не рябит, когда её отдаляют.
    static func texture(asset: String, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        guard let data = ImageAssets.data(asset), let image = ReferenceDecoder.image(data) else { return nil }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }

        // Строки в памяти контекста идут сверху вниз — как и в текстуре Metal.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: pixels, length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if texture.mipmapLevelCount > 1 {
            blit.generateMipmaps(for: texture)
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed ? texture : nil
    }
}
