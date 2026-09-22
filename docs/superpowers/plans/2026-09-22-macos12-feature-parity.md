# macOS 12 Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Make Object Selection and Remove Background available with the same user-facing workflow on macOS 12+ while preserving the native macOS 14+ implementation.

**Architecture:** Add a shared foreground-segmentation boundary. macOS 14 and newer use the existing Vision foreground-instance request; macOS 12 and 13 use a small bundled Core ML DeepLabV3 semantic-segmentation model, Monterey person segmentation, and a deterministic saliency/edge fallback. Both editor features consume masks through the same interface and keep their existing selection/layer-mask behavior.

**Tech Stack:** Swift 5, Vision, Core ML, Core Image, Core Graphics, AppKit, Swift Testing, Xcode.

**Spec:** \`docs/superpowers/specs/2026-09-22-macos12-feature-parity-design.md\`

## Global Constraints

- Keep \`MACOSX_DEPLOYMENT_TARGET\` and \`LSMinimumSystemVersion\` at \`12.0\`.
- Preserve the macOS 14+ \`VNGenerateForegroundInstanceMaskRequest\` path.
- Never return the localized \`error.objectSelection.unsupported\` error on macOS 12 or 13.
- Keep Object Selection's Sample All Layers, edge offset, smoothing, and selection-mode behavior unchanged.
- Keep Remove Background non-destructive and preserve Basic/Advanced controls and existing project serialization.
- Add no runtime network download: the legacy model is bundled in the application.
- Keep inference off the main actor and cap legacy inference input to 1400 px on the long edge.

---

### Task 1: Add the shared segmentation boundary and legacy model backend

**Files:**
- Create: \`Compositor/Document/ForegroundSegmentation.swift\`
- Create: \`Compositor/Resources/Models/DeepLabV3Int8LUT.mlmodel\`
- Create: \`CompositorTests/LegacyForegroundSegmentationTests.swift\`
- Create: \`docs/third-party-models.md\`
- Modify: \`Compositor.xcodeproj/project.pbxproj\`

**Interfaces:**
- Produces \`ForegroundSegmentationBackend\` with \`objectMask(in:at:)\` and \`subjectMask(in:)\` methods returning full-resolution grayscale \`CGImage\` masks.
- Produces \`ForegroundSegmentationFactory.backend()\` that selects the native backend on macOS 14+ and the legacy backend on macOS 12/13.

- [x] **Step 1: Add the failing pure-mask tests.**

Create a synthetic 96×64 RGBA image containing a red rectangle and a blue rectangle separated by black background. Add tests that call the legacy backend's pure mask helpers and assert:

\`\`\`swift
#expect(maskValue(at: CGPoint(x: 20, y: 20)) == 255)
#expect(maskValue(at: CGPoint(x: 70, y: 40)) == 0)
#expect(maskValue(at: CGPoint(x: 2, y: 2)) == 0)
\`\`\`

Add tests for \`edgeOffset\` expansion/contraction and a closed output mask after smoothing. Keep these tests independent of Vision and Core ML by testing the backend's image/mask conversion helpers.

- [x] **Step 2: Run the focused test to confirm it fails before implementation.**

Run:

\`\`\`sh
xcodebuild test -scheme Compositor -destination 'platform=macOS' \\
  -only-testing:CompositorTests/LegacyForegroundSegmentationTests \\
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
\`\`\`

Expected: compile failure because the new backend and mask helpers do not yet exist.

- [x] **Step 3: Add the official compact model and target resource.**

Download Apple's \`DeepLabV3Int8LUT.mlmodel\` from \`https://ml-assets.apple.com/coreml/models/Image/ImageSegmentation/DeepLabV3/DeepLabV3Int8LUT.mlmodel\`, add it to \`Compositor/Resources/Models\`, and add it to the Compositor target's Resources build phase. Record the source URL, model name, 2.3 MB size, and redistribution notice in \`docs/third-party-models.md\`.

- [x] **Step 4: Implement the backend contract and model loader.**

In \`ForegroundSegmentation.swift\`, define:

\`\`\`swift
nonisolated protocol ForegroundSegmentationBackend: Sendable {
    func objectMask(in image: CGImage, at point: CGPoint) throws -> CGImage?
    func subjectMask(in image: CGImage) throws -> CGImage
}
\`\`\`

Implement a lazy \`MLModel\` loader using \`Bundle.main.url(forResource:withExtension:)\` lookup so the app target and unit-test host can both resolve the model. Configure \`MLModelConfiguration.computeUnits = .all\` and cache the compiled model in a lock-protected singleton.

- [x] **Step 5: Convert DeepLabV3 output to masks.**

Use \`MLModel.modelDescription\` to locate the image input and first \`MLMultiArray\` output, resize a \`CGImage\` to the model input, and read the class-id tensor without assuming a fixed output layout. Treat Pascal VOC class \`0\` as background and use the class at the clicked point for Object Selection. Keep only the connected component containing the click; for Remove Background union every non-background class. Convert the result into a full-resolution grayscale \`CGImage\` and pass it through the existing guided-edge/morphology refinement helpers.

- [x] **Step 6: Add Monterey fallbacks and deterministic helpers.**

If model loading or inference fails, try \`VNGeneratePersonSegmentationRequest\` and then use a deterministic fallback that combines \`VNGenerateObjectnessBasedSaliencyImageRequest\`, a click-seeded color/edge flood fill, and the existing mask refinement. Return \`nil\`/\`Failure.noSubject\` only after all three paths fail; never throw \`Failure.unsupported\` from the macOS 12/13 backend.

- [x] **Step 7: Run the focused tests and compatibility check.**

Run the focused test command again and:

\`\`\`sh
./scripts/check-legacy-compatibility.sh
\`\`\`

Expected: focused tests pass, the model resource is present in the built app, and the compatibility script reports success.

- [x] **Step 8: Commit the backend as an independently reviewable change.**

\`\`\`sh
git add Compositor/Document/ForegroundSegmentation.swift \\
  Compositor/Resources/Models/DeepLabV3Int8LUT.mlmodel \\
  CompositorTests/LegacyForegroundSegmentationTests.swift \\
  Compositor.xcodeproj/project.pbxproj docs/third-party-models.md
git commit -m "feat: add macOS 12 foreground segmentation fallback"
\`\`\`

### Task 2: Route Object Selection through the backend

**Files:**
- Modify: \`Compositor/Document/ObjectSelection.swift\`
- Modify: \`CompositorTests/LegacyForegroundSegmentationTests.swift\`

**Interfaces:**
- Consumes \`ForegroundSegmentationFactory.backend()\` from Task 1.
- Produces the existing \`ObjectSelection.select(in:at:edgeOffset:smoothEdges:)\` behavior with no OS-version error on macOS 12/13.

- [x] **Step 1: Add a regression test for the legacy route.**

Add a test that invokes the platform-independent legacy backend with the synthetic two-object image and verifies that a click on object A does not include object B or the background. Add a test that calls the public selection conversion and confirms it returns a closed path rather than \`Failure.unsupported\`.

- [x] **Step 2: Run the test and verify the pre-change failure.**

Run the focused \`LegacyForegroundSegmentationTests\` target. Expected before routing: the current public Object Selection path still throws \`Failure.unsupported\` when compiled for a macOS 12 availability branch.

- [x] **Step 3: Route native and legacy selection.**

Keep the current \`selectAvailable\` method annotated \`@available(macOS 14.0, *)\`. Change \`select(in:at:edgeOffset:smoothEdges:)\` to call \`ForegroundSegmentationFactory.backend().objectMask(in:at:)\`, then run the existing \`adjusted\`, \`MagicWand.outline\`, and smoothing conversion. Remove the macOS 12/13 \`throw Failure.unsupported\` branch while retaining the error case for source compatibility.

- [x] **Step 4: Run Object Selection tests and the Debug build.**

Run the focused tests and:

\`\`\`sh
xcodebuild build -scheme Compositor -configuration Debug \\
  -derivedDataPath /tmp/CompositorDerivedData-macos12-parity-debug \\
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
\`\`\`

Expected: no availability errors and the app still targets macOS 12.0.

- [x] **Step 5: Commit the Object Selection integration.**

\`\`\`sh
git add Compositor/Document/ObjectSelection.swift CompositorTests/LegacyForegroundSegmentationTests.swift
git commit -m "feat: keep object selection available on macOS 12"
\`\`\`

### Task 3: Route Remove Background through the backend

**Files:**
- Modify: \`Compositor/Document/SubjectRemoval.swift\`
- Modify: \`CompositorTests/LegacyForegroundSegmentationTests.swift\`

**Interfaces:**
- Consumes \`ForegroundSegmentationFactory.backend()\` from Task 1.
- Produces the existing \`SubjectRemoval.subjectMask(_:under:settings:)\` and \`SubjectRemoval.run(_:settings:)\` behavior with arbitrary foreground fallback on macOS 12/13.

- [x] **Step 1: Add mask-composition regression tests.**

Add tests that pass a synthetic source and existing mask to \`subjectMask\`, assert that the returned mask is non-empty, and verify that a black pixel in the existing mask remains black. Add a test that \`run\` produces an image with alpha removed outside the foreground mask rather than erasing or mutating the source input.

- [x] **Step 2: Run the tests to confirm the old implementation is insufficient.**

Run the focused test target. Expected before the integration: the current macOS 12 fallback only recognizes person pixels, so the synthetic non-person object test fails or returns \`noSubject\`.

- [x] **Step 3: Replace the hard-coded \`vision(_:)\` implementation with backend selection.**

Keep the current macOS 14 native implementation in a private \`nativeSubjectMask\` helper. Change \`vision(_:) \` to delegate to \`ForegroundSegmentationFactory.backend().subjectMask(in:)\`. Keep the existing cache, guided refinement, settings, existing-mask multiplication, and error-localization behavior unchanged.

- [x] **Step 4: Run Remove Background tests and inspect the generated resource.**

Run the focused test target, confirm the compiled app contains \`DeepLabV3Int8LUT.mlmodelc\`, and run \`git diff --check\`.

- [x] **Step 5: Commit the Remove Background integration.**

\`\`\`sh
git add Compositor/Document/SubjectRemoval.swift CompositorTests/LegacyForegroundSegmentationTests.swift
git commit -m "feat: keep remove background available on macOS 12"
\`\`\`

### Task 4: Full verification and publish

**Files:**
- Modify: \`docs/superpowers/specs/2026-09-22-macos12-feature-parity-design.md\` only if verification discovers a requirement mismatch.
- Test: Debug build, unit tests, compatibility script, universal Release app.

- [ ] **Step 1: Run all focused tests together.**

\`\`\`sh
xcodebuild test-without-building -quiet \\
  -xctestrun /tmp/CompositorDerivedData-macos12-parity-buildtests/Build/Products/Compositor_Compositor_macosx26.2-arm64-x86_64.xctestrun \\
  -destination 'platform=macOS' \\
  -only-testing:CompositorTests/LegacyForegroundSegmentationTests \\
  -only-testing:CompositorTests/LocalizationTests \\
  -parallel-testing-enabled NO
\`\`\`

Expected: focused tests pass on the available host. If Launch Services cannot materialize the Xcode worker, record that infrastructure limitation without treating the tests as passed.

- [ ] **Step 2: Run static and deployment checks.**

\`\`\`sh
git diff --check
./scripts/check-legacy-compatibility.sh
\`\`\`

Expected: no conflict markers, no unguarded macOS APIs, and no deployment target below or above the intended compatibility boundary.

- [ ] **Step 3: Build and inspect Universal Release.**

\`\`\`sh
xcodebuild build -quiet -scheme Compositor -configuration Release \\
  -derivedDataPath /tmp/CompositorDerivedData-macos12-parity-release \\
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
lipo -archs /tmp/CompositorDerivedData-macos12-parity-release/Build/Products/Release/Compositor.app/Contents/MacOS/Compositor
plutil -p /tmp/CompositorDerivedData-macos12-parity-release/Build/Products/Release/Compositor.app/Contents/Info.plist | rg 'CFBundleShortVersionString|LSMinimumSystemVersion'
\`\`\`

Expected: \`x86_64 arm64\`, version \`1.2.2\`, and \`LSMinimumSystemVersion\` equal to \`12.0\`.

- [ ] **Step 4: Commit the verified parity work and push the branch.**

\`\`\`sh
git status --short
git log -3 --oneline
git push https://github.com/vfxbro/Compositor.git legacy-macos-12
\`\`\`

Do not modify PR #60; publish the new commits only on \`vfxbro/Compositor:legacy-macos-12\`.
