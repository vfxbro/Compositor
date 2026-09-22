# Compositor

> **macOS 12+ compatibility fork.** This independent fork tracks upstream Compositor while keeping the app runnable on macOS 12 Monterey and later. It also carries the maintained Russian localization, browser-image paste workflow, Photoshop-style editing shortcuts, and the compatibility fallbacks documented in this repository.

The upstream project currently targets newer macOS releases. Use this fork if you need the same editor workflow on an older Mac. Compatibility work is kept in the [`legacy-macos-12`](https://github.com/vfxbro/Compositor/tree/legacy-macos-12) branch.

## What this fork adds

This fork follows upstream Compositor 1.2.2 and keeps its existing editing features. The changes below are additions to the user workflow, not just build-system changes for older macOS versions.

### macOS 12+ compatibility with feature parity

- The minimum supported version is macOS 12.0 Monterey.
- Release builds are universal and include both Apple Silicon (`arm64`) and Intel (`x86_64`) binaries.
- Newer SwiftUI, Observation, concurrency, and window APIs are isolated behind compatibility helpers so the editor keeps the same workflow on macOS 12–15 and newer systems.
- The Magic/Object selection, Select Subject, and Remove Background tools remain available on macOS 12 and 13. The fork uses the native Vision implementation where it exists and a bundled Core ML fallback model on older systems instead of disabling the tools.
- Compatibility checks and dedicated tests guard the deployment target, Sparkle version, security entitlements, supported architectures, and accidental use of newer APIs.

### Browser image clipboard workflow

- `Command-V` accepts images copied from browsers and other applications even when the clipboard advertises only the generic `public.image` type.
- On an empty document, pasting an image creates a new canvas automatically using the image's pixel dimensions.
- The same behavior works from the New Canvas panel, including when the width or height field is focused.
- Pasted images are added as a centered layer on an existing canvas; images copied inside Compositor preserve their original layer position.
- Text fields keep native text paste behavior, so clipboard image handling does not interfere with normal text editing.

### Photoshop-style keyboard behavior

- `Command-D` deselects the active selection.
- `Command-Z` and `Shift-Command-Z` undo and redo document history.
- `Command-C` and `Command-V` copy and paste canvas pixels as layers.
- Keyboard commands are routed at the canvas level, so they work reliably when the custom canvas or a panel has focus while native text controls retain their own editing commands.
- Keyboard zoom uses stable Photoshop-style zoom stops, keeps the document point under the viewport center, and updates immediately while `Command` is held, including key repeat for `Command-+` and `Command--`.
- Shortcut registration is validated for duplicate commands and conflicting custom overrides.

### English and Russian interface

- The interface can be set to English, Russian, or System Default in `Compositor → Settings…` (`Command-,`).
- The choice is saved between launches and the SwiftUI interface updates immediately.
- Native macOS menu commands use the same selected language after relaunch, including the Settings command.
- Menu labels, tool names, layer names, dialogs, import/export panels, filters, status hints, and common error messages use the shared localization catalog.

### Regression coverage

The fork adds tests for localization persistence, browser clipboard formats, image-sized canvas creation, foreground-mask fallbacks, zoom anchoring and key repeat, keyboard command routing, history round trips, and shortcut-table conflicts. The compatibility checklist is available in [`docs/legacy-macos-12-maintenance.md`](docs/legacy-macos-12-maintenance.md).

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Features

### Layers
- Layers and folders, with blend modes and opacity — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map and Grain
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow and Outer Glow, rendered on the GPU and editable at any time
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate
- Drag layers between open projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one

### Canvas and files
- Multiple projects in tabs
- Rulers (⌘R), guides dragged from them, a layout grid, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, and Option for symmetric cropping
- Canvas Size and Image Size
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF and Photoshop PSD (8-bit RGB only; not PSB or CMYK). PSD folders, masks, a subset of blend modes, and fill rectangles/ellipses stay editable; text and other vectors become pixels. A conversion report is shown before anything is applied.
- Export JPEG with a live preview (⇧⌥⌘S); Copy Merged
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Automatic updates for signed and notarized fork releases

## Requirements

- macOS 12.0 or later
- Xcode 26 or later (to build from source)

## Installing a published build

Download the latest macOS 12+ build from the [Releases](https://github.com/vfxbro/Compositor/releases) page and move `Compositor.app` to `/Applications`.

If macOS shows a first-launch security warning for the current unsigned preview, control-click the app, choose **Open**, and confirm. Only install releases published from this repository or build the app from source yourself. Automatic updates stay disabled until a signed and notarized fork release is published.

## Building

Open `Compositor.xcodeproj` and run the **Compositor** scheme.

The project is configured with a macOS 12.0 deployment target and builds universal `arm64`/`x86_64` binaries. Run `scripts/check-legacy-compatibility.sh` before publishing a change.

## Languages

Compositor supports English, Russian, and System Default. Choose a language in
`Compositor → Settings…` (`⌘,`). The choice is saved for future launches and
the SwiftUI interface updates immediately.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).
