# litter

<p align="center">
  <img src="apps/ios/Sources/Litter/Resources/brand_logo.png" alt="litter logo" width="180" />
</p>

`litter` is a native iOS + Android client for Codex.

## Screenshots (iPhone 17 Pro)

| Dark (Default) | Light |
|---|---|
| ![Dark default](docs/screenshots/iphone17pro/01-dark-default.png) | ![Light mode](docs/screenshots/iphone17pro/02-light.png) |

| Accessibility XXL Text | Dark + High Contrast |
|---|---|
| ![Accessibility content size XXXL](docs/screenshots/iphone17pro/03-accessibility-xxxl.png) | ![Dark with high contrast](docs/screenshots/iphone17pro/04-dark-high-contrast.png) |

## Repository layout

- `apps/ios`: iOS app (`Litter` scheme)
- `apps/android`: Android app
  - `app`: Compose UI shell, app state, server manager, SSH/auth flows
  - `core/bridge`: native bridge bootstrapping and core RPC client
  - `core/network`: discovery services (Bonjour/Tailscale/LAN probing)
  - `docs/qa-matrix.md`: Android parity QA matrix
- `shared/rust-bridge/codex-mobile-client`: single shared Rust mobile client crate and UniFFI surface
- `shared/rust-bridge/codex-ios-audio`: iOS-only audio/AEC crate
- `shared/third_party/codex`: upstream Codex submodule
- `patches/codex`: local Codex patch set
- `tools/scripts`: cross-platform helper scripts

Generated iOS build artifacts under `apps/ios/GeneratedRust/` and packaged frameworks under `apps/ios/Frameworks/` are not stored in git.
Build everything with:

```bash
make ios              # full package lane + simulator build
make ios-device       # full package lane + device build
make ios-device-fast  # fast raw-staticlib device lane
make ios-sim          # full package lane + simulator build
```

## Prerequisites

- **Xcode.app** (full install, not only Command Line Tools). After installing, make sure
  `xcode-select` points to the full Xcode — the Command Line Tools do not include iOS
  simulator SDKs:

  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

- **Rust via rustup** with iOS targets. If you also have Homebrew's `rust` formula
  installed (`brew install rust`), its `cargo`/`rustc` will shadow rustup and break
  cross-compilation. Either `brew uninstall rust` or ensure `~/.cargo/bin` appears
  before `/opt/homebrew/bin` in your `PATH`. The Makefile handles this automatically,
  but standalone script invocations still depend on your shell PATH.

  ```bash
  # Install rustup (skip if already installed)
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

  # Add iOS targets
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```

- **meson** + **ninja** (required by `webrtc-audio-processing-sys` for the audio/AEC
  build):

  ```bash
  brew install meson
  ```

- **xcodegen** (for regenerating `Litter.xcodeproj`):

  ```bash
  brew install xcodegen
  ```

## Connect Your Mac to Litter Over SSH

Use this flow to make Codex sessions from your Mac visible in the iOS/Android app.

1) Enable SSH on the Mac.

- Preferred (UI): `System Settings` -> `General` -> `Sharing` -> enable `Remote Login`.
- CLI option:
  ```bash
  sudo systemsetup -setremotelogin on
  sudo systemsetup -getremotelogin
  ```
- If you get `setremotelogin: Turning Remote Login on or off requires Full Disk Access privileges`, grant Full Disk Access to your terminal app in:
  `System Settings` -> `Privacy & Security` -> `Full Disk Access`, then fully restart terminal and retry.

2) Verify SSH and Codex binaries from a non-interactive SSH shell.

```bash
ssh <mac-user>@<mac-host-or-ip> 'echo ok'
ssh <mac-user>@<mac-host-or-ip> 'command -v codex || command -v codex-app-server'
```

If the second command prints nothing, install Codex and/or fix shell PATH startup files (`.zprofile`, `.zshrc`, `.profile`).

3) Connect from the Litter app.

- Keep phone and Mac on the same LAN (or same Tailnet if using Tailscale).
- In Discovery:
  - If host shows `codex running`, tap to connect directly.
  - If host shows `SSH`, tap and enter SSH credentials; Litter will start remote server via SSH and connect.

4) Fallback: run app-server manually on Mac and add server manually in app.

```bash
codex app-server --listen ws://0.0.0.0:8390
```

Then in app choose `Add Server` and enter `<mac-ip>` + `8390`.

5) Session visibility note.

Thread/session listing is `cwd`-scoped. If expected sessions are missing, choose the same working directory used when those sessions were created.

## Codex source (submodule + patch)

This repo now vendors upstream Codex as a submodule:

- `shared/third_party/codex` -> `https://github.com/openai/codex`

Current local Codex patch set (applied by `sync-codex.sh`):

- `patches/codex/ios-exec-hook.patch`
- `patches/codex/client-controlled-handoff.patch`
- `patches/codex/mobile-code-mode-stub.patch` — stubs out v8/code-mode for iOS/Android targets

Additional patches (not auto-applied):

- `patches/codex/android-vendored-openssl.patch`
- `patches/codex/realtime-transcript-deltas.patch`

Sync/apply patch (idempotent):

```bash
./apps/ios/scripts/sync-codex.sh
```

This preserves the current `shared/third_party/codex` checkout by default, applies the full local patch set, and fails if any patch no longer matches that checkout cleanly.
Pass `--recorded-gitlink` if you explicitly want to reset the submodule to the commit recorded in the superproject.

## Build the Rust bridge

```bash
./apps/ios/scripts/build-rust.sh
```

Useful modes:

```bash
./apps/ios/scripts/build-rust.sh --fast-device
./apps/ios/scripts/build-rust.sh
```

- `--fast-device` builds the raw device staticlib and generated headers only.
- Default/package mode builds device + Apple Silicon simulator slices and also creates `apps/ios/Frameworks/codex_mobile_client.xcframework`.
- Pass `--with-intel-sim` only if you need an Intel Mac simulator slice too.

This script:

1. Preserves the current `shared/third_party/codex` checkout by default, applies the local Codex patch set for the build, and restores the prior patch state afterward
2. Regenerates UniFFI Swift bindings when public Rust boundary inputs change
3. Builds `shared/rust-bridge/codex-mobile-client` for device and/or simulator targets
4. Writes raw artifacts to:
   - `apps/ios/GeneratedRust/Headers`
   - `apps/ios/GeneratedRust/ios-device/libcodex_mobile_client.a`
   - `apps/ios/GeneratedRust/ios-sim/libcodex_mobile_client.a`
5. In package mode, also repackages `apps/ios/Frameworks/codex_mobile_client.xcframework`

Debug/device Xcode builds link the raw `.a` from `apps/ios/GeneratedRust/ios-device/`, not the xcframework.

## Build and run iOS app

Regenerate project if `apps/ios/project.yml` changed:

```bash
./apps/ios/scripts/regenerate-project.sh
```

Open in Xcode:

```bash
open apps/ios/Litter.xcodeproj
```

CLI build example:

```bash
xcodebuild -project apps/ios/Litter.xcodeproj -scheme Litter -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Build and run Android app

Prerequisites:

- Java 17
- Android SDK + build tools for API 35
- Gradle 8.x (or use `apps/android/gradlew`)

Open in Android Studio (macOS):

```bash
open -a "Android Studio" apps/android
```

Rebuild and reopen Android project:

```bash
./apps/android/scripts/rebuild-and-reopen.sh
```

Build Android flavors:

```bash
gradle -p apps/android :app:assembleOnDeviceDebug :app:assembleRemoteOnlyDebug
```

Run Android unit tests:

```bash
cd apps/android && ./gradlew :app:testDebugUnitTest
```

Start emulator and install on-device debug build:

```bash
ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools \
  $ANDROID_SDK_ROOT/emulator/emulator -avd litterApi35

adb -e install -r apps/android/app/build/outputs/apk/onDevice/debug/app-onDevice-debug.apk
adb -e shell am start -n com.sigkitten.litter.android/com.litter.android.MainActivity
```

Build Android Rust JNI libs (optional bridge runtime step):

```bash
./tools/scripts/build-android-rust.sh
```

## TestFlight (iOS)

1) Authenticate `asc` once with your App Store Connect API key:

```bash
asc auth login \
  --name "Litter ASC" \
  --key-id "<KEY_ID>" \
  --issuer-id "<ISSUER_ID>" \
  --private-key "$HOME/AppStore.p8" \
  --network
```

1) Bootstrap TestFlight defaults (internal group, optional review contact metadata):

```bash
APP_BUNDLE_ID=<BUNDLE_ID> \
./apps/ios/scripts/testflight-setup.sh
```

1) Build and upload to TestFlight:

```bash
APP_BUNDLE_ID=<BUNDLE_ID> \
APP_STORE_APP_ID=<APP_STORE_CONNECT_APP_ID> \
TEAM_ID=<APPLE_TEAM_ID> \
ASC_KEY_ID=<KEY_ID> \
ASC_ISSUER_ID=<ISSUER_ID> \
ASC_PRIVATE_KEY_PATH="$HOME/AppStore.p8" \
MARKETING_VERSION=1.0.0 \
./apps/ios/scripts/testflight-upload.sh
```

Notes:

- `testflight-upload.sh` auto-increments build number from the latest App Store Connect build.
- It archives, exports an IPA, uploads via `asc builds upload`, and assigns the build to `Internal Testers` by default.
- Override `SCHEME` if needed (default is `Litter`).

## Important paths

- `apps/ios/project.yml`: source of truth for Xcode project/schemes
- `shared/rust-bridge/codex-mobile-client/`: single Rust mobile client crate and UniFFI surface
- `shared/rust-bridge/codex-ios-audio/`: iOS-only audio/AEC crate
- `shared/third_party/codex/`: upstream Codex source (submodule)
- `patches/codex/`: local Codex patch set applied to the submodule during Rust/iOS builds
- `apps/ios/GeneratedRust/`: generated UniFFI headers/modulemap and raw iOS staticlibs used by Debug/device builds
- `apps/ios/Sources/Litter/Bridge/`: Swift bridge + JSON-RPC client
- `apps/android/app/src/main/java/com/litter/android/ui/`: Android Compose UI shell and screens
- `apps/android/app/src/main/java/com/litter/android/state/`: Android state, transports, session/server orchestration
- `apps/android/core/bridge/`: Android bridge bootstrap and core websocket client
- `apps/android/core/network/`: discovery services
- `apps/android/app/src/test/java/`: Android unit tests (runtime mode + transport policy scaffolding)
- `apps/android/docs/qa-matrix.md`: Android parity checklist
- `tools/scripts/build-android-rust.sh`: builds Android JNI Rust artifacts into `jniLibs`
- `apps/ios/Sources/Litter/Resources/brand_logo.svg`: source logo (SVG)
- `apps/ios/Sources/Litter/Resources/brand_logo.png`: in-app logo image used by `BrandLogo`
- `apps/ios/Sources/Litter/Assets.xcassets/AppIcon.appiconset/`: generated app icon set

## Branding assets

- Home/launch branding uses `BrandLogo` (`apps/ios/Sources/Litter/Views/BrandLogo.swift`) backed by `brand_logo.png`.
- The app icon is generated from the same logo and stored in `AppIcon.appiconset`.
- If logo art changes, regenerate icon sizes from `Icon-1024.png` (or re-run your ImageMagick resize pipeline) before building.
