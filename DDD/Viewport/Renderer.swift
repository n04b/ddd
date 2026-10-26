//
//  Renderer.swift
//  Рисует сцену поверх прозрачного фона окна: тела, сетку стола,
//  отверстия и маски (контуром или заливкой), объекты с флагом «контур», подсветку выделения.
//

import Foundation
import MetalKit
import simd

struct GPUUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var color: SIMD4<Float>
    var cameraPos: SIMD4<Float>
    var params: SIMD4<Float>
}

struct OutlineUniforms {
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var params: SIMD4<Float>
}

struct GPUMesh {
    let buffer: MTLBuffer
    let count: Int
}

enum Palette {
    static let solid = SIMD4<Float>(0.68, 0.72, 0.79, 1)
    static let solidSelected = SIMD4<Float>(0.52, 0.80, 0.93, 1)
    static let hole = SIMD4<Float>(1.00, 0.62, 0.25, 0.30)
    static let holeXray = SIMD4<Float>(1.00, 0.62, 0.25, 0.07)
    static let holeOutline = SIMD4<Float>(1.00, 0.62, 0.25, 0.85)
    static let mask = SIMD4<Float>(0.72, 0.58, 1.00, 0.22)
    static let maskXray = SIMD4<Float>(0.72, 0.58, 1.00, 0.06)
    static let maskOutline = SIMD4<Float>(0.72, 0.58, 1.00, 0.85)
    static let solidOutline = SIMD4<Float>(0.86, 0.89, 0.95, 0.70)
    static let solidGhost = SIMD4<Float>(0.68, 0.72, 0.79, 0.30)
    static let solidGhostXray = SIMD4<Float>(0.68, 0.72, 0.79, 0.07)
    static let selection = SIMD4<Float>(0.30, 0.84, 0.98, 0.30)
    static let selectionXray = SIMD4<Float>(0.30, 0.84, 0.98, 0.10)
    static let filletXray = SIMD4<Float>(0.68, 0.72, 0.79, 0.30)
    static let gridMinor = SIMD4<Float>(1, 1, 1, 0.05)
    static let gridMajor = SIMD4<Float>(1, 1, 1, 0.10)
    static let plateOutline = SIMD4<Float>(1, 1, 1, 0.24)
    static let axisX = SIMD4<Float>(1.00, 0.38, 0.38, 0.70)
    static let axisY = SIMD4<Float>(0.38, 0.90, 0.52, 0.70)
}

final class Renderer: NSObject, MTKViewDelegate {
    weak var model: EditorModel?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let outlinePipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthTest: MTLDepthStencilState
    private let depthAlways: MTLDepthStencilState
    private let grid: [(mesh: GPUMesh, color: SIMD4<Float>)]
    private var meshBuffers: [UUID: GPUMesh] = [:]
    private var uploadedGeneration = -1
    private var maskTextures: (msaa: MTLTexture, resolved: MTLTexture)?

    /// Толщина контуров отверстий и масок, pt.
    static let outlineWidth: Float = 1.5

    /// Размер стола, мм (Bambu Lab / Prusa MK4 — около 250).
    static let plateSize: Float = 256

    init?(view: MTKView, model: EditorModel) {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            print("Renderer: Metal is unavailable")
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.main, options: nil)
        } catch {
            print("Renderer: shader compilation failed: \(error)")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vmain")
        descriptor.fragmentFunction = library.makeFunction(name: "fmain")
        descriptor.rasterSampleCount = view.sampleCount
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        // Альфа накапливается так, чтобы результат был premultiplied —
        // так его ждёт прозрачный CAMetalLayer поверх размытого фона окна.
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let maskDescriptor = MTLRenderPipelineDescriptor()
        maskDescriptor.vertexFunction = library.makeFunction(name: "vmain")
        maskDescriptor.fragmentFunction = library.makeFunction(name: "fmask")
        maskDescriptor.rasterSampleCount = view.sampleCount
        maskDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        // Силуэты в разных каналах перекрываются: каналы не должны затирать друг друга.
        maskDescriptor.colorAttachments[0].isBlendingEnabled = true
        maskDescriptor.colorAttachments[0].rgbBlendOperation = .max
        maskDescriptor.colorAttachments[0].alphaBlendOperation = .max
        maskDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        maskDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        maskDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        maskDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        let outlineDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
        outlineDescriptor.vertexFunction = library.makeFunction(name: "voutline")
        outlineDescriptor.fragmentFunction = library.makeFunction(name: "foutline")

        let pipeline: MTLRenderPipelineState
        let maskPipeline: MTLRenderPipelineState
        let outlinePipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            maskPipeline = try device.makeRenderPipelineState(descriptor: maskDescriptor)
            outlinePipeline = try device.makeRenderPipelineState(descriptor: outlineDescriptor)
        } catch {
            print("Renderer: failed to build pipeline: \(error)")
            return nil
        }

        guard let depthWrite = Renderer.depthState(device, .less, write: true),
              let depthTest = Renderer.depthState(device, .lessEqual, write: false),
              let depthAlways = Renderer.depthState(device, .always, write: false) else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.maskPipeline = maskPipeline
        self.outlinePipeline = outlinePipeline
        self.depthWrite = depthWrite
        self.depthTest = depthTest
        self.depthAlways = depthAlways
        self.grid = Renderer.makeGrid(device: device, plate: Renderer.plateSize)
        self.model = model
        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let model else { return }
        syncMeshes(model.output)

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        let camera = model.camera
        let viewProj = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix()
        let eye = camera.eye

        func encode(_ encoder: MTLRenderCommandEncoder, _ mesh: GPUMesh, _ color: SIMD4<Float>, lit: Bool,
                    depth: MTLDepthStencilState?, primitive: MTLPrimitiveType = .triangle,
                    model: simd_float4x4 = matrix_identity_float4x4) {
            var uniforms = GPUUniforms(viewProj: viewProj,
                                       model: model,
                                       color: color,
                                       cameraPos: SIMD4<Float>(eye.x, eye.y, eye.z, 1),
                                       params: SIMD4<Float>(lit ? 1 : 0, 0, 0, 0))
            if let depth { encoder.setDepthStencilState(depth) }
            encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: mesh.count)
        }

        // Положения берём из документа, а не из результата ядра:
        // перетаскиваемый объект двигается сразу, не дожидаясь пересчёта.
        let document = model.doc
        let selected = Set(model.selection)
        let scene = Renderer.collect(document)

        // В режиме контуров соседи выделенного объекта по группе рисуются заливкой,
        // как и он сам, а остальные отверстия и маски — контуром. Вне режима
        // заливкой рисуются все отверстия и маски.
        let outlineMode = model.outlineMode
        var siblings: [UUID] = []
        for id in model.selection where outlineMode {
            guard let parent = document.parentID(of: id), let group = document.node(parent) else { continue }
            for child in group.children where !selected.contains(child.id) && !siblings.contains(child.id) {
                siblings.append(child.id)
            }
        }
        let filled = outlineMode ? selected.union(siblings) : Set(scene.holes + scene.masks)

        // 0. Остальные отверстия и маски рисуются только контуром; объекты с флагом
        // «контур» и их потомки — тоже, в любом режиме. Сначала силуэты складываются
        // в маску (отверстия — красный канал, маски — зелёный, тела — синий),
        // потом по краю каждого канала идёт линия.
        let forced = scene.outlined
        let layers: [(ids: [UUID], color: SIMD4<Float>)] = [
            (scene.holes.filter { forced.contains($0) || !filled.contains($0) }, Palette.holeOutline),
            (scene.masks.filter { forced.contains($0) || !filled.contains($0) }, Palette.maskOutline),
            (scene.solids.filter { forced.contains($0) }, Palette.solidOutline),
        ]
        var outlineMask: (texture: MTLTexture, uniforms: OutlineUniforms)?
        let outlined = layers.map { $0.ids.filter { meshBuffers[$0] != nil } }
        if outlined.contains(where: { !$0.isEmpty }),
           let targets = maskTargets(for: size, sampleCount: view.sampleCount) {
            let maskPass = MTLRenderPassDescriptor()
            maskPass.colorAttachments[0].texture = targets.msaa
            maskPass.colorAttachments[0].resolveTexture = targets.resolved
            maskPass.colorAttachments[0].loadAction = .clear
            maskPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            maskPass.colorAttachments[0].storeAction = .multisampleResolve
            if let maskEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass) {
                maskEncoder.setRenderPipelineState(maskPipeline)
                maskEncoder.setCullMode(.none)
                for (channel, ids) in outlined.enumerated() {
                    var unit = SIMD4<Float>.zero
                    unit[channel] = 1
                    for id in ids {
                        guard let mesh = meshBuffers[id], let matrix = scene.matrices[id] else { continue }
                        encode(maskEncoder, mesh, unit, lit: false, depth: nil, model: matrix)
                    }
                }
                maskEncoder.endEncoding()
                let scale = Float(size.width / max(view.bounds.width, 1))
                outlineMask = (targets.resolved,
                               OutlineUniforms(colors: (layers[0].color, layers[1].color, layers[2].color, .zero),
                                               params: SIMD4<Float>(Renderer.outlineWidth * scale * 0.5, 0, 0, 0)))
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        func submit(_ mesh: GPUMesh, _ color: SIMD4<Float>, lit: Bool,
                    depth: MTLDepthStencilState, primitive: MTLPrimitiveType = .triangle,
                    model: simd_float4x4 = matrix_identity_float4x4) {
            encode(encoder, mesh, color, lit: lit, depth: depth, primitive: primitive, model: model)
        }

        // 1. Тела верхнего уровня — это печатаемые детали. Деталь с флагом «контур»
        // заливкой не рисуется; выделенная, она подсвечивается как объект в группе.
        var parts = Set<UUID>()
        let xray = model.filletXrayPart
        for node in document.nodes where node.visible && node.mode == .solid && !forced.contains(node.id) {
            parts.insert(node.id)
            if node.id == xray { continue }
            guard let mesh = meshBuffers[node.id], let matrix = scene.matrices[node.id] else { continue }
            submit(mesh, selected.contains(node.id) ? Palette.solidSelected : Palette.solid,
                   lit: true, depth: depthWrite, model: matrix)
        }

        // 2. Стол.
        for line in grid {
            submit(line.mesh, line.color, lit: false, depth: depthTest, primitive: .line)
        }

        // 3. Контуры — одной линией по внешнему контуру, внутри пусто.
        if var outlineMask {
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setDepthStencilState(depthAlways)
            encoder.setFragmentTexture(outlineMask.texture, index: 0)
            encoder.setFragmentBytes(&outlineMask.uniforms, length: MemoryLayout<OutlineUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.setRenderPipelineState(pipeline)
        }
        // Выделенные и их соседи по группе — заливкой: видимая часть плотнее,
        // скрытая внутри тела — едва заметно.
        for id in scene.holes where filled.contains(id) && !forced.contains(id) {
            guard let mesh = meshBuffers[id], let matrix = scene.matrices[id] else { continue }
            submit(mesh, Palette.holeXray, lit: false, depth: depthAlways, model: matrix)
            submit(mesh, Palette.hole, lit: true, depth: depthTest, model: matrix)
        }
        for id in scene.masks where filled.contains(id) && !forced.contains(id) {
            guard let mesh = meshBuffers[id], let matrix = scene.matrices[id] else { continue }
            submit(mesh, Palette.maskXray, lit: false, depth: depthAlways, model: matrix)
            submit(mesh, Palette.mask, lit: true, depth: depthTest, model: matrix)
        }
        for id in siblings where !parts.contains(id) && !forced.contains(id) && document.node(id)?.mode == .solid {
            guard let mesh = meshBuffers[id], let matrix = scene.matrices[id] else { continue }
            submit(mesh, Palette.solidGhostXray, lit: false, depth: depthAlways, model: matrix)
            submit(mesh, Palette.solidGhost, lit: true, depth: depthTest, model: matrix)
        }

        // 3½. Деталь в режиме скруглений — рентгеном: задние и нижние рёбра видны сквозь тело.
        if let xray, let mesh = meshBuffers[xray], let matrix = scene.matrices[xray] {
            submit(mesh, Palette.filletXray, lit: true, depth: depthTest, model: matrix)
        }

        // 4. Выделенные объекты внутри групп.
        for id in model.selection where !parts.contains(id) {
            guard let mesh = meshBuffers[id], let matrix = scene.matrices[id] else { continue }
            submit(mesh, Palette.selectionXray, lit: false, depth: depthAlways, model: matrix)
            submit(mesh, Palette.selection, lit: true, depth: depthTest, model: matrix)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Данные

    /// Текстуры маски контуров; пересоздаются при смене размера окна.
    private func maskTargets(for size: CGSize, sampleCount: Int) -> (msaa: MTLTexture, resolved: MTLTexture)? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if let targets = maskTextures, targets.resolved.width == width, targets.resolved.height == height {
            return targets
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let resolved = device.makeTexture(descriptor: descriptor) else { return nil }
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = sampleCount
        descriptor.usage = .renderTarget
        guard let msaa = device.makeTexture(descriptor: descriptor) else { return nil }
        maskTextures = (msaa, resolved)
        return maskTextures
    }

    private func syncMeshes(_ output: KernelOutput) {
        guard output.generation != uploadedGeneration else { return }
        uploadedGeneration = output.generation
        var buffers: [UUID: GPUMesh] = [:]
        for (id, mesh) in output.meshes where mesh.vertexCount > 0 {
            let length = mesh.data.count * MemoryLayout<Float>.stride
            if let buffer = device.makeBuffer(bytes: mesh.data, length: length, options: .storageModeShared) {
                buffers[id] = GPUMesh(buffer: buffer, count: mesh.vertexCount)
            }
        }
        meshBuffers = buffers
    }

    /// Мировые матрицы видимых узлов; видимые тела, отверстия и маски на всех уровнях;
    /// узлы, которые рисуются контуром из-за своего флага или флага предка.
    private static func collect(_ document: SceneDocument)
        -> (matrices: [UUID: simd_float4x4], solids: [UUID], holes: [UUID], masks: [UUID], outlined: Set<UUID>) {
        var matrices: [UUID: simd_float4x4] = [:]
        var solids: [UUID] = []
        var holes: [UUID] = []
        var masks: [UUID] = []
        var outlined = Set<UUID>()
        func walk(_ nodes: [Node], parent: Pose, outline: Bool) {
            for node in nodes where node.visible {
                let pose = parent * node.pose
                let outline = outline || node.outlined == true
                matrices[node.id] = matrix(pose)
                switch node.mode {
                case .solid: solids.append(node.id)
                case .hole: holes.append(node.id)
                case .mask: masks.append(node.id)
                }
                if outline { outlined.insert(node.id) }
                walk(node.children, parent: pose, outline: outline)
            }
        }
        walk(document.nodes, parent: .identity, outline: false)
        return (matrices, solids, holes, masks, outlined)
    }

    private static func matrix(_ pose: Pose) -> simd_float4x4 {
        let r = pose.rotation
        let t = pose.translation
        return simd_float4x4(columns: (
            SIMD4<Float>(Float(r.r0.x), Float(r.r1.x), Float(r.r2.x), 0),
            SIMD4<Float>(Float(r.r0.y), Float(r.r1.y), Float(r.r2.y), 0),
            SIMD4<Float>(Float(r.r0.z), Float(r.r1.z), Float(r.r2.z), 0),
            SIMD4<Float>(Float(t.x), Float(t.y), Float(t.z), 1)
        ))
    }

    private static func depthState(_ device: MTLDevice, _ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = compare
        descriptor.isDepthWriteEnabled = write
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    private static func makeGrid(device: MTLDevice, plate: Float) -> [(mesh: GPUMesh, color: SIMD4<Float>)] {
        let half = plate / 2
        var minor: [(SIMD3<Float>, SIMD3<Float>)] = []
        var major: [(SIMD3<Float>, SIMD3<Float>)] = []
        var v = -floor(half / 10) * 10
        while v <= half + 0.001 {
            let alongY = (SIMD3<Float>(v, -half, 0), SIMD3<Float>(v, half, 0))
            let alongX = (SIMD3<Float>(-half, v, 0), SIMD3<Float>(half, v, 0))
            if abs(v.truncatingRemainder(dividingBy: 50)) < 0.001 {
                major.append(alongY)
                major.append(alongX)
            } else {
                minor.append(alongY)
                minor.append(alongX)
            }
            v += 10
        }
        let a = SIMD3<Float>(-half, -half, 0)
        let b = SIMD3<Float>(half, -half, 0)
        let c = SIMD3<Float>(half, half, 0)
        let d = SIMD3<Float>(-half, half, 0)
        let outline = [(a, b), (b, c), (c, d), (d, a)]
        let lift: Float = 0.02
        let axisX = [(SIMD3<Float>(0, 0, lift), SIMD3<Float>(half, 0, lift))]
        let axisY = [(SIMD3<Float>(0, 0, lift), SIMD3<Float>(0, half, lift))]

        var result: [(mesh: GPUMesh, color: SIMD4<Float>)] = []
        for (segments, color) in [(minor, Palette.gridMinor), (major, Palette.gridMajor),
                                  (outline, Palette.plateOutline), (axisX, Palette.axisX),
                                  (axisY, Palette.axisY)] {
            if let mesh = lineMesh(device, segments) {
                result.append((mesh, color))
            }
        }
        return result
    }

    private static func lineMesh(_ device: MTLDevice, _ segments: [(SIMD3<Float>, SIMD3<Float>)]) -> GPUMesh? {
        var data: [Float] = []
        data.reserveCapacity(segments.count * 16)
        for (p, q) in segments {
            let chunk: [Float] = [p.x, p.y, p.z, 0, 0, 0, 1, 0,
                                  q.x, q.y, q.z, 0, 0, 0, 1, 0]
            data.append(contentsOf: chunk)
        }
        guard !data.isEmpty,
              let buffer = device.makeBuffer(bytes: data,
                                             length: data.count * MemoryLayout<Float>.stride,
                                             options: .storageModeShared) else { return nil }
        return GPUMesh(buffer: buffer, count: segments.count * 2)
    }
}
