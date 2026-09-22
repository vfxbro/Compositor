# macOS 12 Feature Parity Design

## Goal

Keep the user-visible feature set of the current upstream Compositor release available on macOS 12 and newer. The implementation may use different system APIs or bundled processing on older systems, but the user must not lose the ability to perform the operation because of the OS version.

## Scope

This pass closes the two compatibility gaps identified in the v1.2.2 forward-port:

1. Object Selection currently returns `unsupported` below macOS 14.
2. Remove Background uses person-only segmentation below macOS 14, so arbitrary foreground objects are not handled like the upstream path.

Other existing compatibility paths remain in place: rasterized `CGPath` boolean operations, legacy SwiftUI change observation, CPU/CI blend fallbacks, and older cursor/scroll behavior.

## User-visible contract

On every supported OS version:

- Object Selection is available from the same tool/menu entry, accepts a point on the visible composite, respects Sample All Layers, edge offset, smoothing, and the current selection mode, and produces a normal document selection.
- Remove Background is available for people and non-person foreground objects, keeps its Basic/Advanced controls, and applies a non-destructive layer mask rather than erasing pixels.
- Ambiguous imagery may produce “no subject found” or an empty selection, but it must not report “requires macOS 14” on macOS 12 or 13.
- Existing project files, selection history, localization keys, and menu behavior remain unchanged.

Pixel-for-pixel equality with Apple's macOS 14 Vision model is not required. Functional parity means the same operation is present, accepts the same inputs, exposes the same controls, and returns the same kind of editable result.

## Architecture

Introduce a small foreground-segmentation boundary used by both features:

```swift
nonisolated protocol ForegroundSegmentationBackend: Sendable {
    func objectMask(in image: CGImage, at point: CGPoint) throws -> CGImage?
    func subjectMask(in image: CGImage) throws -> CGImage
}
```

The native backend keeps the existing macOS 14+ `VNGenerateForegroundInstanceMaskRequest` implementation. The legacy backend is used on macOS 12 and 13 and combines three compatible paths in order:

1. A bundled redistributable semantic foreground model accessed through Core ML/Vision, selecting the connected component containing the clicked class for Object Selection and the union of foreground classes for Remove Background.
2. `VNGeneratePersonSegmentationRequest` for people, which is available on Monterey and provides a high-quality fast path for portraits.
3. A deterministic saliency/edge/seeded-region fallback for images or model outputs that do not produce a usable mask.

The model and image-processing implementation remain behind the boundary. `ObjectSelection` and `SubjectRemoval` only request a mask, refine it with the existing guided-edge and morphology code, and convert it to the existing selection or layer-mask representation.

## Processing and performance

- Downsample inference to the existing preview limits (maximum 1400 px for background removal and 800 px for live RAW-style previews), then refine/upscale against the full-resolution guide image.
- Cache the loaded model and the subject mask by source image identity and settings-independent input hash.
- Run inference and mask conversion in the existing detached user-initiated tasks; update `EditorSession` state only on the main actor.
- Keep the native macOS 14+ path unchanged so newer systems retain Apple's optimized implementation.

## Error handling

- `unsupported` is removed from the macOS 12/13 execution path.
- A model load or inference failure falls through to the next backend rather than disabling the command.
- If all backends fail, return the existing localized “no subject found” or render error, preserving the current error presentation.
- Do not silently erase or modify pixels when a mask cannot be generated.

## Testing and acceptance

Add focused tests for the platform-independent legacy backend using synthetic images containing separate colored foreground regions:

- A click selects only the connected foreground object under the click.
- Edge offset expands/contracts the mask and smoothing preserves a closed selectable path.
- Remove Background returns a mask, not an erased image, and combines with an existing mask by multiplication.
- A backend failure falls through without producing an `unsupported` error.

Retain existing native-path tests and add availability-guard tests that compile the legacy implementation with the macOS 12 deployment target. On the development Mac, verify Debug/Release compilation and run the focused unit tests; run the full UI suite on a normal Xcode host where Launch Services can materialize the test worker.

## Non-goals

- Do not raise the minimum deployment target.
- Do not change the saved project schema or add a new user-facing mode switch.
- Do not replace the macOS 14+ native Vision implementation.
- Do not promise identical segmentation contours across OS generations.

