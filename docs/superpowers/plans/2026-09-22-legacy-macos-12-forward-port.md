# Legacy macOS 12 Forward-Port Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a maintainable `legacy-macos-12` branch that follows upstream Compositor releases from `v1.2.2` onward while preserving the fork's macOS 12 support, localization, browser clipboard paste, and Photoshop-style zoom behavior.

**Architecture:** Keep upstream `main` as the source of new features and keep the fork's compatibility work in explicit compatibility files and narrowly scoped guards. Start a new forward-port branch from the already tested fork, merge upstream `v1.2.2`, resolve conflicts by preserving behavior and saved-file identifiers, then publish the branch to `vfxbro/Compositor` without rewriting the existing historical PR.

**Tech Stack:** Swift 5, SwiftUI, AppKit, Combine, Core Graphics, ImageIO, Core Image, Metal with CPU fallback, Sparkle 2.10.0, Xcode, `xcodebuild`, Swift Testing, XCTest, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-09-21-legacy-macos-support-design.md`

## Global Constraints

- Preserve macOS 12.0 as the minimum deployment target and keep universal `x86_64`/`arm64` Release builds.
- Preserve English/Russian localization, persisted language selection, the single native Settings command, browser clipboard image paste, and immediate Command +/- zoom.
- Preserve project-file identifiers, Codable keys, UTIs, bundle identifiers, Sparkle configuration, App Sandbox, and existing security entitlements.
- Do not modify or close PR #60 during this integration; the new branch is the maintainable follow-up line.
- Do not claim runtime support on Monterey without a Monterey runtime check; build and static availability checks are mandatory, real Monterey testing is a release gate when hardware is available.

### Task 1: Capture the pre-forward-port baseline

**Files:**
- Inspect: Git status, current branch, tags, upstream `main), existing compatibility checks, and current build metadata.
- Create: local safety branch `legacy-macos-support-pre-1.2.2`.

- [x] **Step 1: Verify the checkout is clean and record the current fork commit.**

Run:

```sh
git status --short --branch
git log -1 --format='%H %s'
git diff --check
```

Expected: no uncommitted files, the current commit is `bf5068a`, and `git diff --check` is silent.

- [x] **Step 2: Preserve the existing PR branch before creating the new line.**

Run:

```sh
git branch legacy-macos-support-pre-1.2.2 legacy-macos-support
```

Expected: a local pointer exists at the current tested fork state; no files change.

### Task 2: Create the v1.2.2 forward-port branch

**Files:**
- Modify: Git refs only; no source edits until the merge result is inspected.

- [x] **Step 1: Fetch the latest upstream main and verify the release boundary.**

Run:

```sh
git fetch origin main --tags
git show -s --format='%H%n%s%n%ad' v1.2.2
git log -1 --oneline origin/main
```

Expected: tag `v1.2.2` resolves to the upstream 1.2.2 release and `origin/main` is not behind that release.

- [x] **Step 2: Create the permanent forward-port branch from the tested fork.**

Run:

```sh
git switch -c legacy-macos-12 legacy-macos-support
```

Expected: `legacy-macos-12` points to the same code as the current fork before upstream changes.

- [x] **Step 3: Merge the upstream release without discarding fork changes.**

Run:

```sh
git merge --no-ff v1.2.2 -m "Merge upstream v1.2.2 into legacy macOS 12 fork"
```

Expected: either a clean merge or a conflict list limited to files changed by both upstream 1.2.2 and the fork. Do not use `git reset --hard` or discard the pre-merge safety branch.

### Task 3: Resolve and test the compatibility boundary

**Files:**
- Modify only files reported by the merge: `Compositor.xcodeproj/project.pbxproj`, compatibility helpers, `Compositor/CompositorApp.swift`, `Compositor/ContentView.swift`, `Compositor/Rendering/EditorCanvas.swift`, localization/UI files, and affected tests.
- Preserve: `Compositor/Compatibility/*`, `Compositor/Localization/*`, `Compositor/Resources/Localizable.xcstrings`, `Compositor/IO/SelectionClipboard.swift`, and the fork's Settings delegate path unless the upstream change is demonstrably compatible.

- [x] **Step 1: Inventory conflicts and classify each one before editing.**

Run:

```sh
git status --short
git diff --name-only --diff-filter=U
```

For each conflict, classify it as upstream feature code, macOS compatibility code, localization/menu code, clipboard/project persistence, or test/project wiring. Do not resolve a conflict by taking one whole side when the file contains both categories.

- [x] **Step 2: Resolve project wiring and version metadata.**

Keep all upstream 1.2.2 source/test references, retain compatibility files in the Xcode target, and keep the fork's deployment targets at `12.0`. Preserve version/build metadata semantics and do not change persisted project identifiers.

- [x] **Step 3: Resolve app commands and localization.**

Keep exactly one working native Settings command, preserve English/Russian selection and restart behavior, and add English/Russian catalog entries for any new 1.2.2 strings. Never duplicate the Settings command or reintroduce a SwiftUI `Settings` scene that creates a second menu item.

- [x] **Step 4: Resolve rendering/input and clipboard conflicts.**

Keep immediate Command +/- zoom on keyDown/repeat, browser image paste into New Canvas, and existing layer/project behavior. Integrate upstream blend-mode and adjustment changes without changing raw saved identifiers or clipboard text filtering.

- [x] **Step 5: Run static checks before committing the merge.**

Run:

```sh
git diff --check
./scripts/check-legacy-compatibility.sh
```

Expected: no whitespace errors and no unguarded forbidden APIs, incompatible deployment targets, or security regressions. If the script reports a genuine upstream 1.2.2 API, add the smallest compatibility guard and a focused test before proceeding.

### Task 4: Verify upstream 1.2.2 features and fork regressions

**Files:**
- Modify: affected tests only if the upstream release changed an assertion or a new fork regression is exposed.
- Test: `CompositorTests`, `CompositorUITests`, and focused clipboard/localization/zoom tests.

- [x] **Step 1: Build Debug with signing disabled.**

Run:

```sh
xcodebuild build -scheme Compositor -configuration Debug -derivedDataPath /tmp/CompositorDerivedData-v1.2.2-debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: exit code 0 and a Debug app built with the macOS 12 deployment target.

- [ ] **Step 2: Run focused fork regression tests.**

Run the existing targeted test path for localization, Settings/menu behavior, clipboard image paste, canvas size inference, and Command +/- zoom. If Swift Testing filtering is unavailable on the host, use the existing temporary XCTest wrapper method and remove the wrapper afterward.

Expected: every targeted test passes, including repeated Command +/- keyDown behavior.

- [ ] **Step 3: Run the full available unit-test suite.**

Run:

```sh
xcodebuild test -scheme Compositor -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Expected: no new failures attributable to the v1.2.2 merge. Record unavailable UI tests separately rather than marking them passed.

- [x] **Step 4: Build and inspect a universal Release app.**

Run a Release build with `ONLY_ACTIVE_ARCH=NO`, then verify:

```sh
lipo -archs /tmp/CompositorDerivedData-v1.2.2-release/Build/Products/Release/Compositor.app/Contents/MacOS/Compositor
codesign --verify --deep --strict /tmp/CompositorDerivedData-v1.2.2-release/Build/Products/Release/Compositor.app
```

Expected: `x86_64 arm64` and successful ad-hoc verification.

**Execution note:** Debug and `build-for-testing` completed successfully. The Xcode test runner did not materialize an `xctest` worker in this environment and stalled at the local Launch Services worker; the full unit/UI test run was interrupted and is not counted as passed. Runtime tests remain a release gate on a normal Xcode host.

### Task 5: Commit and publish the maintainable fork line

**Files:**
- Create: merge commit and any focused follow-up commits.
- Publish: branch `legacy-macos-12` to `https://github.com/vfxbro/Compositor`.

- [x] **Step 1: Review the final merge diff.**

Run:

```sh
git status --short
git diff --stat origin/main...HEAD
git diff --check
```

Confirm the diff contains upstream 1.2.2 plus the documented compatibility/localization/clipboard/zoom scope and no generated build artifacts.

- [x] **Step 2: Commit the resolved forward-port.**

Run:

```sh
git add Compositor.xcodeproj Compositor CompositorTests CompositorUITests Config README.md docs scripts
git commit -m "Merge upstream v1.2.2 into legacy macOS 12 fork"
```

Expected: one reproducible commit containing only the forward-port and required fixes.

- [x] **Step 3: Push the new branch to the fork.**

Run:

```sh
git push https://github.com/vfxbro/Compositor.git legacy-macos-12
```

Expected: branch `legacy-macos-12` is visible in the user fork; do not force-push and do not alter PR #60.

### Task 6: Establish the recurring update workflow

**Files:**
- Modify: `docs/project-format.md` or a new fork maintenance document only if the workflow is not already documented.

- [x] **Step 1: Document the release-forward sequence.**

The documented sequence must be:

```sh
git fetch origin main --tags
git switch legacy-macos-12
git merge --no-ff vX.Y.Z -m "Merge upstream vX.Y.Z into legacy macOS 12 fork"
./scripts/check-legacy-compatibility.sh
xcodebuild build -scheme Compositor -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git push https://github.com/vfxbro/Compositor.git legacy-macos-12
```

- [x] **Step 2: Record the support policy.**

Document that upstream compatibility policy remains macOS 26.5, while this fork intentionally maintains macOS 12+ with explicit fallbacks and accepts the maintenance cost of resolving new API conflicts.
