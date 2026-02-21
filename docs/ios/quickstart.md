# iOS Quickstart

## Prerequisites
- Xcode.app
- xcodegen (`brew install xcodegen`)
- Rust iOS targets:
  - `aarch64-apple-ios`
  - `aarch64-apple-ios-sim`
  - `x86_64-apple-ios`

## Build Steps
1. Sync Codex submodule + apply iOS patch:
   - `./apps/ios/scripts/sync-codex.sh`
2. Build Rust bridge XCFramework:
   - `./apps/ios/scripts/build-rust.sh`
3. Generate project:
   - `xcodegen generate --spec apps/ios/project.yml --project apps/ios/Litter.xcodeproj`
4. Build app:
   - `xcodebuild -project apps/ios/Litter.xcodeproj -scheme Litter -configuration Debug -destination 'generic/platform=iOS Simulator' build`

## Schemes
- `LitterRemote`: remote-only mode.
- `Litter`: includes on-device Rust bridge XCFramework.
