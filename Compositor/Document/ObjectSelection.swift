import AppKit

nonisolated struct ObjectSelectionSettings: Equatable, Sendable {
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = true
    /// Positive values erode the detected mask inward; negative values expand it outward.
    var edgeOffset = 0
}

/// Selects the foreground object under a clicked point using Vision's instance mask,
/// then traces that mask into the document's normal path-based selection.
nonisolated enum ObjectSelection {
    enum Failure: LocalizedError {
        case unsupported
        case render

        var errorDescription: String? {
            switch self {
            case .unsupported: L10n.text("error.objectSelection.unsupported")
            case .render: L10n.text("error.objectSelection.render")
            }
        }
    }

    /// The outline, in the image's top-left pixel coordinates, of the foreground object
    /// at `point`. Nil when the point is outside the image, on background, or no object is found.
    static func select(in image: CGImage, at point: CGPoint, edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let maskImage = try ForegroundSegmentationFactory.backend().objectMask(in: image, at: point)
        guard let maskImage else { return nil }
        let binaryMask = try ForegroundMaskUtilities.grayscaleBytes(from: maskImage, width: width, height: height)
        return try path(from: binaryMask, width: width, height: height, edgeOffset: edgeOffset, smoothEdges: smoothEdges)
    }

    /// Converts a backend mask into the path representation used by the editor. This remains separate
    /// from Vision/Core ML so the legacy route can be regression-tested without a particular OS model.
    static func path(from binaryMask: [UInt8], width: Int, height: Int,
                     edgeOffset: Int, smoothEdges: Bool) throws -> CGPath? {
        let mask = ForegroundMaskUtilities.adjusted(binaryMask, width: width, height: height, edgeOffset: edgeOffset)
        guard let outline = try MagicWand.outline(of: mask, width: width, height: height) else { return nil }
        return smoothEdges ? smoothed(outline) : outline
    }

    /// Rounds off the one-pixel stair steps created by tracing a binary mask. The winding and
    /// subpath order are preserved, so holes continue to subtract from the selected region.
    private static func smoothed(_ path: CGPath) -> CGPath {
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finishCurrent() {
            guard current.count >= 3 else { current.removeAll(); return }
            subpaths.append(current)
            current.removeAll()
        }
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                finishCurrent()
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .addQuadCurveToPoint:
                current.append(element.points[1])
            case .addCurveToPoint:
                current.append(element.points[2])
            case .closeSubpath:
                finishCurrent()
            @unknown default:
                break
            }
        }
        finishCurrent()

        let result = CGMutablePath()
        for subpath in subpaths {
            let simplified = simplifyClosed(subpath, tolerance: 1.6)
            let points = chaikin(simplified, iterations: 3)
            guard let first = points.first else { continue }
            result.move(to: first)
            result.addLines(between: Array(points.dropFirst()))
            result.closeSubpath()
        }
        return result
    }

    private static func simplifyClosed(_ input: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 4 else { return points }
        // Break at a stable extreme so the open-polyline simplifier can preserve the whole closed contour.
        let start = points.indices.min { lhs, rhs in
            points[lhs].x == points[rhs].x ? points[lhs].y < points[rhs].y : points[lhs].x < points[rhs].x
        } ?? points.startIndex
        let rotated = Array(points[start...]) + Array(points[..<start])
        var open = rotated + [rotated[0]]
        open = simplifyOpen(open, from: 0, to: open.count - 1, tolerance: tolerance)
        if open.first == open.last { open.removeLast() }
        return open.count >= 3 ? open : points
    }

    private static func simplifyOpen(_ points: [CGPoint], from first: Int, to last: Int, tolerance: CGFloat) -> [CGPoint] {
        guard last > first + 1 else { return [points[first], points[last]] }
        var farthest = first + 1
        var greatestDistance: CGFloat = 0
        for index in (first + 1)..<last {
            let distance = perpendicularDistance(points[index], toLineFrom: points[first], to: points[last])
            if distance > greatestDistance {
                greatestDistance = distance
                farthest = index
            }
        }
        guard greatestDistance > tolerance else { return [points[first], points[last]] }
        var left = simplifyOpen(points, from: first, to: farthest, tolerance: tolerance)
        let right = simplifyOpen(points, from: farthest, to: last, tolerance: tolerance)
        left.removeLast()
        return left + right
    }

    private static func perpendicularDistance(_ point: CGPoint, toLineFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        return abs(dy * point.x - dx * point.y + b.x * a.y - b.y * a.x) / length
    }

    private static func chaikin(_ input: [CGPoint], iterations: Int) -> [CGPoint] {
        var points = input
        if points.first == points.last { points.removeLast() }
        guard points.count >= 3 else { return points }
        for _ in 0..<iterations {
            var next: [CGPoint] = []
            next.reserveCapacity(points.count * 2)
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            points = next
        }
        return points
    }

    @available(macOS 14.0, *)
    private static func grayscaleBytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        try grayscaleBytes(from: CIImage(cvPixelBuffer: pixelBuffer), width: width, height: height, interpolation: interpolation)
    }

    @available(macOS 14.0, *)
    private static func grayscaleBytes(from image: CIImage, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        let renderer = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cgImage = renderer.createCGImage(image, from: image.extent) else { throw Failure.render }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        guard let data = context.data else { throw Failure.render }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = source[y * context.bytesPerRow + x]
            }
        }
        return bytes
    }
}

private nonisolated struct ObjectSelectionJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
    let edgeOffset: Int
    let smoothEdges: Bool
}

private nonisolated struct ObjectSelectionResult: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}

extension EditorSession {
    /// Object Selection: selects the Vision foreground instance under `point`, read from
    /// the active layer or every visible layer, combined with the current selection by `mode`.
    func selectObject(at point: CGPoint, mode: SelectionMode) async {
        guard canEditSelection, !isProjectBusy, selectionMoveOrigin == nil, let document,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: objectSelectionSettings.sampleAllLayers) else { return }
        let job = ObjectSelectionJob(image: sample, point: point,
                                     edgeOffset: min(10, max(-10, objectSelectionSettings.edgeOffset)),
                                     smoothEdges: selectionAntialiased)
        isProjectBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> ObjectSelectionResult in
            do { return ObjectSelectionResult(path: try ObjectSelection.select(in: job.image, at: job.point, edgeOffset: job.edgeOffset, smoothEdges: job.smoothEdges), error: nil) }
            catch { return ObjectSelectionResult(path: nil, error: error) }
        }.value
        isProjectBusy = false
        if let error = result.error { brushError = error.localizedDescription; return }
        guard self.document?.id == document.id else { return }
        guard let path = result.path else {
            if mode == .replace { deselect() }
            return
        }
        if mode == .replace {
            setSelection(DocumentSelection(path: path, antialiased: selectionAntialiased), name: "Object Selection")
        } else {
            applySelection(path, mode: mode, name: "Object Selection")
        }
    }
}
