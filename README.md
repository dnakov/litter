# litter (codex-ios)

<p align="center">
  <img src="apps/ios/Sources/Litter/Resources/brand_logo.png" alt="litter logo" width="180" />
</p>

`litter` is an iOS client for Codex. It supports:

- `LitterRemote`: remote-only mode (default scheme; no bundled on-device Rust server)
- `Litter`: includes the on-device Rust bridge (`codex_bridge.xcframework`)

## Prerequisites

- Xcode.app (full install, not only CLT)
- Rust + iOS targets:
  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```
- `xcodegen` (for regenerating `Litter.xcodeproj`):
  ```bash
  brew install xcodegen
  ```

## Codex source (submodule + patch)

This repo now vendors upstream Codex as a submodule:

- `shared/third_party/codex` -> `https://github.com/openai/codex`

On-device iOS exec hook changes are kept as a local patch:

- `patches/codex/ios-exec-hook.patch`

Sync/apply patch (idempotent):

```bash
./apps/ios/scripts/sync-codex.sh
```

## Build the Rust bridge

```bash
./apps/ios/scripts/build-rust.sh
```

This script:

1. Syncs `shared/third_party/codex` and applies the iOS hook patch
2. Builds `shared/rust-bridge/codex-bridge` for device + simulator targets
3. Repackages `apps/ios/Frameworks/codex_bridge.xcframework`

## Build and run iOS app

Regenerate project if `apps/ios/project.yml` changed:

```bash
xcodegen generate --spec apps/ios/project.yml --project apps/ios/Litter.xcodeproj
```

Open in Xcode:

```bash
open apps/ios/Litter.xcodeproj
```

Schemes:

- `LitterRemote` (default): no on-device Rust bridge
- `Litter`: uses bundled `codex_bridge.xcframework`

CLI build example:

```bash
xcodebuild -project apps/ios/Litter.xcodeproj -scheme LitterRemote -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Important paths

- `apps/ios/project.yml`: source of truth for Xcode project/schemes
- `shared/rust-bridge/codex-bridge/`: Rust staticlib wrapper exposing `codex_start_server`/`codex_stop_server`
- `shared/third_party/codex/`: upstream Codex source (submodule)
- `patches/codex/ios-exec-hook.patch`: iOS-specific hook patch applied to submodule
- `apps/ios/Sources/Litter/Bridge/`: Swift bridge + JSON-RPC client
- `apps/ios/Sources/Litter/Resources/brand_logo.svg`: source logo (SVG)
- `apps/ios/Sources/Litter/Resources/brand_logo.png`: in-app logo image used by `BrandLogo`
- `apps/ios/Sources/Litter/Assets.xcassets/AppIcon.appiconset/`: generated app icon set

## Branding assets

- Home/launch branding uses `BrandLogo` (`apps/ios/Sources/Litter/Views/BrandLogo.swift`) backed by `brand_logo.png`.
- The app icon is generated from the same logo and stored in `AppIcon.appiconset`.
- If logo art changes, regenerate icon sizes from `Icon-1024.png` (or re-run your ImageMagick resize pipeline) before building.
