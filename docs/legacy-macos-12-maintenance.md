# Legacy macOS 12 fork maintenance

The `legacy-macos-12` branch is a forward-port of Compositor that follows upstream releases while keeping macOS 12 as the minimum supported system.

## Compatibility policy

- Keep `MACOSX_DEPLOYMENT_TARGET` and `LSMinimumSystemVersion` at `12.0`.
- Preserve the fork's Russian/English localization, clipboard image paste, and immediate Command +/- zoom behavior.
- Port upstream features and fixes whenever they can be implemented without raising the minimum OS version.
- Isolate newer SDK APIs behind the compatibility helpers in `Compositor/Compatibility`.

## Updating from upstream

```sh
git fetch https://github.com/robbietilton/Compositor.git main --tags
git switch legacy-macos-12
git merge --no-ff <upstream-tag> -m "Merge upstream <upstream-tag> into legacy macOS 12 fork"
```

Resolve conflicts by keeping upstream functionality and reapplying the compatibility/localization changes where necessary. Before publishing an update, run:

```sh
./scripts/check-legacy-compatibility.sh
xcodebuild build -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorDerivedData-debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

For a distributable build, use `ONLY_ACTIVE_ARCH=NO`, then verify the result contains both `arm64` and `x86_64`, reports version `1.2.x`, and has `LSMinimumSystemVersion` set to `12.0`.
