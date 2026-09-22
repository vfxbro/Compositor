import CoreGraphics
import CoreImage
import Testing
@testable import Compositor

struct LegacyForegroundSegmentationTests {
    @Test func connectedComponentKeepsOnlyTheClickedObject() {
        let mask = twoObjectMask(width: 96, height: 64)

        let selected = ForegroundMaskUtilities.connectedComponent(
            in: mask,
            width: 96,
            height: 64,
            at: CGPoint(x: 20, y: 20)
        )

        #expect(selected != nil)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 20, y: 20), in: selected!, width: 96, height: 64) == 255)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 70, y: 40), in: selected!, width: 96, height: 64) == 0)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 2, y: 2), in: selected!, width: 96, height: 64) == 0)
    }

    @Test func edgeOffsetExpandsAndContractsTheMask() {
        var source = [UInt8](repeating: 0, count: 15 * 15)
        for y in 5..<10 {
            for x in 5..<10 {
                source[y * 15 + x] = 255
            }
        }

        let expanded = ForegroundMaskUtilities.adjusted(source, width: 15, height: 15, edgeOffset: -2)
        let contracted = ForegroundMaskUtilities.adjusted(source, width: 15, height: 15, edgeOffset: 2)

        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 3, y: 7), in: expanded, width: 15, height: 15) == 255)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 5, y: 5), in: contracted, width: 15, height: 15) == 0)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 7, y: 7), in: contracted, width: 15, height: 15) == 255)
    }

    @Test func closingProducesAClosedForegroundMask() {
        var source = [UInt8](repeating: 0, count: 17 * 17)
        for y in 4..<13 {
            for x in 4..<13 where !(x == 8 && y == 4) {
                source[y * 17 + x] = 255
            }
        }

        let closed = ForegroundMaskUtilities.closed(source, width: 17, height: 17)

        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 8, y: 4), in: closed, width: 17, height: 17) == 255)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 2, y: 2), in: closed, width: 17, height: 17) == 0)
    }

    @Test func maskImageRoundTripPreservesDimensionsAndValues() throws {
        let source = twoObjectMask(width: 96, height: 64)
        let image = try ForegroundMaskUtilities.cgImage(from: source, width: 96, height: 64)
        let roundTrip = try ForegroundMaskUtilities.grayscaleBytes(from: image, width: 96, height: 64)

        #expect(image.width == 96)
        #expect(image.height == 64)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 20, y: 20), in: roundTrip, width: 96, height: 64) == 255)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 2, y: 2), in: roundTrip, width: 96, height: 64) == 0)
    }

    @Test func objectSelectionConversionReturnsAClosedPath() throws {
        let mask = twoObjectMask(width: 96, height: 64)
        let path = try ObjectSelection.path(from: mask, width: 96, height: 64, edgeOffset: 0, smoothEdges: true)

        #expect(path != nil)
        var closeCount = 0
        path?.applyWithBlock { element in
            if element.pointee.type == .closeSubpath { closeCount += 1 }
        }
        #expect(closeCount > 0)
    }

    @Test func subjectMaskKeepsExistingHiddenPixelsHidden() throws {
        var subject = [UInt8](repeating: 0, count: 12 * 12)
        var existing = [UInt8](repeating: 255, count: 12 * 12)
        for y in 2..<10 {
            for x in 2..<10 { subject[y * 12 + x] = 255 }
        }
        existing[5 * 12 + 5] = 0

        let combined = try SubjectRemoval.combinedMask(
            try ForegroundMaskUtilities.cgImage(from: subject, width: 12, height: 12),
            under: try ForegroundMaskUtilities.cgImage(from: existing, width: 12, height: 12)
        )
        let bytes = try ForegroundMaskUtilities.grayscaleBytes(from: combined, width: 12, height: 12)

        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 3, y: 3), in: bytes, width: 12, height: 12) > 0)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 5, y: 5), in: bytes, width: 12, height: 12) == 0)
        #expect(ForegroundMaskUtilities.value(at: CGPoint(x: 0, y: 0), in: bytes, width: 12, height: 12) == 0)
    }

    @Test func applyingMaskRemovesAlphaWithoutMutatingSource() throws {
        var mask = [UInt8](repeating: 0, count: 12 * 12)
        for y in 0..<12 {
            for x in 0..<6 { mask[y * 12 + x] = 255 }
        }
        let maskImage = try ForegroundMaskUtilities.cgImage(from: mask, width: 12, height: 12)
        let source = try solidImage(width: 12, height: 12, color: CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))

        let output = try SubjectRemoval.apply(mask: CIImage(cgImage: maskImage), to: source)
        let outputBytes = try ForegroundMaskUtilities.rgbaBytes(from: output, width: 12, height: 12)
        let sourceBytes = try ForegroundMaskUtilities.rgbaBytes(from: source, width: 12, height: 12)

        #expect(outputBytes[(4 * 12 + 2) * 4 + 3] == 255)
        #expect(outputBytes[(4 * 12 + 9) * 4 + 3] == 0)
        #expect(sourceBytes[(4 * 12 + 9) * 4 + 3] == 255)
    }

    private func twoObjectMask(width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 12..<36 {
            for x in 12..<36 { result[y * width + x] = 255 }
        }
        for y in 28..<52 {
            for x in 60..<84 { result[y * width + x] = 255 }
        }
        return result
    }

    private func solidImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}
