# iOS Quickstart

## Prerequisites
- Xcode.app
- xcodegen (`brew install xcodegen`)
- Rust toolchain (`rustup`)
- Optional: sccache (`brew install sccache`) for faster Rust rebuilds

## Build with Make (recommended)

```bash
# Full iOS build (device + simulator)
make ios

# Simulator only (faster)
make ios-sim

# Device only
make ios-device

# Build + open Xcode
make ios-run
```

This handles submodule sync, patching, UniFFI bindings, Rust cross-compilation, xcframework creation, ios_system framework download, Xcode project generation, and the Xcode build — with caching so repeated runs skip completed steps.

## Build manually (step by step)
1. Sync Codex submodule + apply iOS patch:
   - `./apps/ios/scripts/sync-codex.sh`
   - This preserves the current submodule checkout by default. Use `--recorded-gitlink` only if you want to reset to the commit recorded in the parent repo.
2. Build Rust bridge XCFramework:
   - `./apps/ios/scripts/build-rust.sh`
   - Add `--with-intel-sim` only if you need an Intel Mac simulator slice.
3. Download ios_system frameworks:
   - `./apps/ios/scripts/download-ios-system.sh`
4. Generate project:
   - `./apps/ios/scripts/regenerate-project.sh`
5. Build app:
   - `xcodebuild -project apps/ios/Litter.xcodeproj -scheme Litter -configuration Debug -destination 'generic/platform=iOS Simulator' build`

## Configuration
Override via environment variables:
- `IOS_SIM_DEVICE="iPhone 16"` — change simulator target
- `XCODE_CONFIG=Release` — release build
