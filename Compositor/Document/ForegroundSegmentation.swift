import AppKit
import CoreGraphics
import CoreImage
import CoreML
import Vision

/// The common contract used by foreground tools. Implementations always return a full-resolution,
/// top-left grayscale mask so the editor can keep its existing selection and layer-mask plumbing.
nonisolated protocol ForegroundSegmentationBackend: Sendable {
    func objectMask(in image: CGImage, at point: CGPoint) throws -> CGImage?
    func subjectMask(in image: CGImage) throws -> CGImage
}

nonisolated enum ForegroundSegmentationFactory {
    static func backend() -> any ForegroundSegmentationBackend {
        if #available(macOS 14.0, *) {
            return NativeForegroundSegmentationBackend()
        }
        return LegacyForegroundSegmentationBackend()
    }
}

enum ForegroundSegmentationError: Error {
    case noSubject
    case modelUnavailable
    case invalidModelOutput
}

/// Pure mask operations shared by the legacy backend and tests. Keeping these independent of Vision
/// makes the most failure-prone coordinate and morphology code testable on every supported release.
nonisolated enum ForegroundMaskUtilities {
    static func value(at point: CGPoint, in mask: [UInt8], width: Int, height: Int) -> UInt8 {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y), mask.count == width * height else { return 0 }
        return mask[y * width + x]
    }

    static func adjusted(_ source: [UInt8], width: Int, height: Int, edgeOffset: Int) -> [UInt8] {
        guard source.count == width * height else { return [] }
        var result = source
        for _ in 0..<min(10, abs(edgeOffset)) {
            result = edgeOffset > 0 ? eroded(result, width: width, height: height)
                                    : dilated(result, width: width, height: height)
        }
        return result
    }

    /// A one-pixel closing removes isolated pinholes while retaining the outside contour.
    static func closed(_ source: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard source.count == width * height else { return [] }
        return eroded(dilated(source, width: width, height: height), width: width, height: height)
    }

    static func connectedComponent(in source: [UInt8], width: Int, height: Int, at point: CGPoint) -> [UInt8]? {
        guard source.count == width * height else { return nil }
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y), source[y * width + x] != 0 else { return nil }

        var result = [UInt8](repeating: 0, count: source.count)
        var queue = [Int](); queue.reserveCapacity(source.count / 8)
        var head = 0
        let start = y * width + x
        queue.append(start)
        result[start] = 255
        while head < queue.count {
            let index = queue[head]; head += 1
            let cx = index % width, cy = index / width
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = cx + dx, ny = cy + dy
                    guard (0..<width).contains(nx), (0..<height).contains(ny) else { continue }
                    let neighbor = ny * width + nx
                    guard source[neighbor] != 0, result[neighbor] == 0 else { continue }
                    result[neighbor] = 255
                    queue.append(neighbor)
                }
            }
        }
        return result
    }

    static func cgImage(from mask: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, mask.count == width * height,
              let provider = CGDataProvider(data: Data(mask) as CFData) else { throw ExportError.render }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ExportError.render }
        return image
    }

    static func grayscaleBytes(from image: CGImage, width: Int, height: Int,
                               interpolation: CGInterpolationQuality = .none) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ExportError.render }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        context.interpolationQuality = interpolation
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let source = data.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // CGContext bitmap memory is bottom-up; expose the editor's top-left convention.
                result[y * width + x] = source[(height - 1 - y) * context.bytesPerRow + x]
            }
        }
        return result
    }

    static func binaryImage(from mask: [UInt8], width: Int, height: Int) throws -> CGImage {
        try cgImage(from: mask.map { $0 >= 128 ? 255 : 0 }, width: width, height: height)
    }

    static func rgbaBytes(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ExportError.render }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw ExportError.render }
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let source = data.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let destination = (y * width + x) * 4
                let sourceOffset = ((height - 1 - y) * context.bytesPerRow) + x * 4
                result[destination] = source[sourceOffset]
                result[destination + 1] = source[sourceOffset + 1]
                result[destination + 2] = source[sourceOffset + 2]
                result[destination + 3] = source[sourceOffset + 3]
            }
        }
        return result
    }

    private static func eroded(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                var keep = true
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] == 0 {
                        keep = false
                    }
                }
                result[y * width + x] = keep ? 255 : 0
            }
        }
        return result
    }

    private static func dilated(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 0 {
                var fill = false
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where mask[ny * width + nx] != 0 {
                        fill = true
                    }
                }
                if fill { result[y * width + x] = 255 }
            }
        }
        return result
    }
}

@available(macOS 14.0, *)
private struct NativeForegroundSegmentationBackend: ForegroundSegmentationBackend {
    func objectMask(in image: CGImage, at point: CGPoint) throws -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        guard let instance = try instanceIndex(in: observation.instanceMask, at: point,
                                               imageSize: CGSize(width: image.width, height: image.height)),
              observation.allInstances.contains(instance) else { return nil }
        let coarse = try observation.generateMask(forInstances: IndexSet(integer: instance))
        let mask = try refinedMask(from: coarse, guide: image, width: image.width, height: image.height)
        return try ForegroundMaskUtilities.binaryImage(from: mask, width: image.width, height: image.height)
    }

    func subjectMask(in image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ForegroundSegmentationError.noSubject
        }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return try PixelAdjust.render(CIImage(cvPixelBuffer: buffer), width: image.width, height: image.height, isMask: true)
    }

    private func instanceIndex(in pixelBuffer: CVPixelBuffer, at point: CGPoint, imageSize: CGSize) throws -> Int? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let gray = try PixelAdjust.render(CIImage(cvPixelBuffer: pixelBuffer), width: width, height: height, isMask: true)
        let bytes = try ForegroundMaskUtilities.grayscaleBytes(from: gray, width: width, height: height)
        let x = min(width - 1, max(0, Int((point.x / imageSize.width) * CGFloat(width))))
        let y = min(height - 1, max(0, Int((point.y / imageSize.height) * CGFloat(height))))
        let value = Int(bytes[y * width + x])
        return value == 0 ? nil : value
    }

    private func refinedMask(from pixelBuffer: CVPixelBuffer, guide: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let coarse = CIImage(cvPixelBuffer: pixelBuffer)
        let guideImage = CIImage(cgImage: guide)
        let refined: CIImage
        if let filter = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            filter.setValue(guideImage, forKey: kCIInputImageKey)
            filter.setValue(coarse, forKey: "inputSmallImage")
            filter.setValue(5, forKey: "inputSpatialSigma")
            filter.setValue(0.15, forKey: "inputLumaSigma")
            refined = filter.outputImage ?? coarse
        } else {
            refined = coarse
        }
        let image = try PixelAdjust.render(refined, width: width, height: height, isMask: true)
        return try ForegroundMaskUtilities.grayscaleBytes(from: image, width: width, height: height)
    }
}

private nonisolated final class ModelResourceMarker: NSObject {}

private nonisolated final class DeepLabModelStore: @unchecked Sendable {
    static let shared = DeepLabModelStore()
    private let lock = NSLock()
    private var cached: MLModel?

    func model() throws -> MLModel {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()

        guard let url = Self.modelURL() else { throw ForegroundSegmentationError.modelUnavailable }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded: MLModel
        if url.pathExtension == "mlmodelc" {
            loaded = try MLModel(contentsOf: url, configuration: configuration)
        } else {
            let compiled = try MLModel.compileModel(at: url)
            loaded = try MLModel(contentsOf: compiled, configuration: configuration)
        }
        lock.lock(); cached = loaded; lock.unlock()
        return loaded
    }

    private static func modelURL() -> URL? {
        let bundles = [Bundle.main, Bundle(for: ModelResourceMarker.self)]
        for bundle in bundles {
            if let compiled = bundle.url(forResource: "DeepLabV3Int8LUT", withExtension: "mlmodelc") { return compiled }
            if let source = bundle.url(forResource: "DeepLabV3Int8LUT", withExtension: "mlmodel") { return source }
        }
        return nil
    }
}

/// macOS 12/13 backend. DeepLabV3 supplies semantic classes; connected components turn the
/// clicked class into the instance-like behavior users expect from Object Selection.
nonisolated struct LegacyForegroundSegmentationBackend: ForegroundSegmentationBackend {
    private static let inputSize = 513
    private static let maximumInferenceEdge: CGFloat = 1400

    func objectMask(in image: CGImage, at point: CGPoint) throws -> CGImage? {
        if let classes = try? semanticClasses(in: image),
           let mask = semanticObjectMask(classes, width: image.width, height: image.height, at: point) {
            return try ForegroundMaskUtilities.binaryImage(from: mask, width: image.width, height: image.height)
        }
        if let mask = try? personMask(in: image),
           let selected = ForegroundMaskUtilities.connectedComponent(in: mask, width: image.width, height: image.height, at: point) {
            return try ForegroundMaskUtilities.binaryImage(from: selected, width: image.width, height: image.height)
        }
        guard let selected = colorFloodMask(in: image, at: point) else { return nil }
        return try ForegroundMaskUtilities.binaryImage(from: selected, width: image.width, height: image.height)
    }

    func subjectMask(in image: CGImage) throws -> CGImage {
        if let classes = try? semanticClasses(in: image) {
            let mask = semanticSubjectMask(classes, width: image.width, height: image.height)
            if mask.contains(where: { $0 != 0 }) {
                return try ForegroundMaskUtilities.binaryImage(from: mask, width: image.width, height: image.height)
            }
        }
        if let mask = try? personMask(in: image), mask.contains(where: { $0 != 0 }) {
            return try ForegroundMaskUtilities.binaryImage(from: mask, width: image.width, height: image.height)
        }
        if let mask = try? saliencyMask(in: image), mask.contains(where: { $0 != 0 }) {
            return try ForegroundMaskUtilities.binaryImage(from: ForegroundMaskUtilities.closed(mask, width: image.width, height: image.height),
                                                           width: image.width, height: image.height)
        }
        throw ForegroundSegmentationError.noSubject
    }

    private func semanticClasses(in image: CGImage) throws -> [UInt8] {
        let model = try DeepLabModelStore.shared.model()
        guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key,
              let output = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key
        else { throw ForegroundSegmentationError.invalidModelOutput }
        let buffer = try Self.pixelBuffer(from: image, size: Self.inputSize)
        let provider = try MLDictionaryFeatureProvider(dictionary: [input: MLFeatureValue(pixelBuffer: buffer)])
        let prediction = try model.prediction(from: provider)
        guard let array = prediction.featureValue(for: output)?.multiArrayValue else {
            throw ForegroundSegmentationError.invalidModelOutput
        }
        let grid = try Self.classGrid(from: array)
        var classes = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let modelY = min(grid.height - 1, max(0, Int(CGFloat(y) / CGFloat(image.height) * CGFloat(grid.height))))
            for x in 0..<image.width {
                let modelX = min(grid.width - 1, max(0, Int(CGFloat(x) / CGFloat(image.width) * CGFloat(grid.width))))
                classes[y * image.width + x] = grid.value(modelX, modelY)
            }
        }
        return classes
    }

    private func semanticObjectMask(_ classes: [UInt8], width: Int, height: Int, at point: CGPoint) -> [UInt8]? {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        guard classes[y * width + x] != 0 else { return nil }
        var classMask = [UInt8](repeating: 0, count: classes.count)
        let target = classes[y * width + x]
        for index in classes.indices where classes[index] == target { classMask[index] = 255 }
        return ForegroundMaskUtilities.connectedComponent(in: classMask, width: width, height: height, at: point)
    }

    private func semanticSubjectMask(_ classes: [UInt8], width: Int, height: Int) -> [UInt8] {
        classes.map { $0 == 0 ? 0 : 255 }
    }

    private func personMask(in image: CGImage) throws -> [UInt8] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw ForegroundSegmentationError.noSubject }
        let rendered = try PixelAdjust.render(CIImage(cvPixelBuffer: buffer), width: image.width, height: image.height, isMask: true)
        return try ForegroundMaskUtilities.grayscaleBytes(from: rendered, width: image.width, height: image.height)
    }

    private func saliencyMask(in image: CGImage) throws -> [UInt8] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw ForegroundSegmentationError.noSubject }
        let rendered = try PixelAdjust.render(CIImage(cvPixelBuffer: buffer), width: image.width, height: image.height, isMask: true)
        let values = try ForegroundMaskUtilities.grayscaleBytes(from: rendered, width: image.width, height: image.height,
                                                                interpolation: .high)
        return values.map { $0 >= 64 ? 255 : 0 }
    }

    private func colorFloodMask(in image: CGImage, at point: CGPoint) -> [UInt8]? {
        guard let context = try? BrushRaster.context(width: image.width, height: image.height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { return nil }
        let start = y * image.width + x
        let startOffset = start * 4
        let red = Int(pixels[startOffset]), green = Int(pixels[startOffset + 1]), blue = Int(pixels[startOffset + 2])
        let toleranceSquared = 70 * 70
        var result = [UInt8](repeating: 0, count: image.width * image.height)
        var queue = [Int](arrayLiteral: start); var head = 0; result[start] = 255
        while head < queue.count {
            let index = queue[head]; head += 1
            let cx = index % image.width, cy = index / image.width
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = cx + dx, ny = cy + dy
                    guard (0..<image.width).contains(nx), (0..<image.height).contains(ny) else { continue }
                    let neighbor = ny * image.width + nx
                    guard result[neighbor] == 0 else { continue }
                    let offset = neighbor * 4
                    let dr = Int(pixels[offset]) - red, dg = Int(pixels[offset + 1]) - green, db = Int(pixels[offset + 2]) - blue
                    guard dr * dr + dg * dg + db * db <= toleranceSquared else { continue }
                    result[neighbor] = 255
                    queue.append(neighbor)
                }
            }
        }
        return result.contains(where: { $0 != 0 }) ? result : nil
    }

    private struct ClassGrid {
        let width: Int
        let height: Int
        let values: [Int32]
        func value(_ x: Int, _ y: Int) -> UInt8 {
            UInt8(clamping: values[y * width + x])
        }
    }

    private static func classGrid(from array: MLMultiArray) throws -> ClassGrid {
        let shape = array.shape.map(\.intValue)
        let dimensions = shape.indices.filter { shape[$0] > 1 }
        guard dimensions.count >= 2 else { throw ForegroundSegmentationError.invalidModelOutput }
        let yDimension = dimensions[dimensions.count - 2], xDimension = dimensions[dimensions.count - 1]
        let height = shape[yDimension], width = shape[xDimension]
        var values = [Int32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var indices = [NSNumber](repeating: 0, count: shape.count)
                indices[yDimension] = NSNumber(value: y)
                indices[xDimension] = NSNumber(value: x)
                values[y * width + x] = array[indices].int32Value
            }
        }
        return ClassGrid(width: width, height: height, values: values)
    }

    private static func pixelBuffer(from image: CGImage, size: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attributes, &result) == kCVReturnSuccess,
              let buffer = result else { throw ForegroundSegmentationError.modelUnavailable }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: size, height: size, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw ForegroundSegmentationError.modelUnavailable }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}
