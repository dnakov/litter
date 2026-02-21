# Repository Guidelines

## Project Structure & Module Organization
- `apps/ios/Sources/Litter/` contains the iOS app code.
- `apps/ios/Sources/Litter/Views/` holds SwiftUI screens, `Models/` contains app state/session logic, and `Bridge/` contains JSON-RPC + C FFI bridge code.
- `apps/android/app/src/main/java/com/litter/android/ui/` contains Android Compose shell/screens.
- `apps/android/app/src/main/java/com/litter/android/state/` contains Android app state, server/session manager, SSH, and websocket transport.
- `apps/android/core/bridge/` contains Android core native bridge bootstrap and websocket client.
- `apps/android/core/network/` contains Android discovery services (Bonjour/Tailscale/LAN probing).
- `apps/android/app/src/test/java/` contains Android unit tests.
- `apps/android/docs/qa-matrix.md` tracks Android parity QA coverage.
- `shared/rust-bridge/codex-bridge/` is the shared Rust library (`libcodex_bridge.a`) exposed through `shared/rust-bridge/codex-bridge/include/codex_bridge.h`.
- `shared/third_party/codex/` is the upstream Codex submodule.
- `apps/ios/Frameworks/` stores iOS XCFrameworks (`codex_bridge.xcframework` and `ios_system/*`).
- `apps/ios/project.yml` is the source of truth for project generation; regenerate `apps/ios/Litter.xcodeproj` instead of hand-editing project files.

## Architecture
- **iOS root layout:** `ContentView` uses a `ZStack` with a persistent `HeaderView`, main content area, and a `SidebarOverlay` that slides from the left.
- **iOS state management:** `ConversationStore` (ObservableObject) manages WebSocket connection, JSON-RPC calls, and message state. `AppState` (ObservableObject) manages UI state (sidebar, server, model/reasoning selection).
- **iOS server flow:** `DiscoveryView` (sheet) discovers and connects to servers; sidebar/session flows use `thread/list`, `thread/resume`, and `thread/start`.
- **Android root layout:** `LitterAppShell` is the Compose entry; `DefaultLitterAppState` maps backend state into UI state.
- **Android state/transport:** `ServerManager` handles multi-server threads/models/account state and routes notifications via `BridgeRpcTransport`.
- **Android server flow:** Discovery sheet + SSH login sheet + settings/account sheets drive connection, auth, and server management.
- **Message rendering parity:** both platforms support reasoning/system sections, code block rendering, and inline image handling.

## Dependencies
### iOS (SPM via `apps/ios/project.yml`)
- **Citadel** — SSH client for remote server connections.
- **MarkdownUI** — Renders Markdown in assistant/system messages with custom theming.
- **Inject** — Hot reload support for simulator development (Debug builds only).
### Android (Gradle)
- **Compose Material3** — primary Android UI toolkit.
- **Markwon** — Markdown rendering for assistant/system text.
- **JSch** — SSH transport for remote bootstrap flow.
- **androidx.security:security-crypto** — encrypted credential storage.

## Build, Test, and Development Commands
- `./apps/ios/scripts/download-ios-system.sh`: download required `ios_system` XCFrameworks.
- `./apps/ios/scripts/build-rust.sh`: cross-compile Rust bridge from `shared/rust-bridge/codex-bridge` for device/simulator and rebuild `apps/ios/Frameworks/codex_bridge.xcframework`.
- `xcodegen generate --spec apps/ios/project.yml --project apps/ios/Litter.xcodeproj`: regenerate iOS project after spec/path changes.
- `open apps/ios/Litter.xcodeproj`: open and run from Xcode.
- `xcodebuild -project apps/ios/Litter.xcodeproj -scheme Litter -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`: CI-friendly local build.
- `gradle -p apps/android :app:assembleOnDeviceDebug :app:assembleRemoteOnlyDebug`: build Android flavors.
- `gradle -p apps/android :app:testOnDeviceDebugUnitTest :app:testRemoteOnlyDebugUnitTest`: run Android unit tests.
- `adb -e install -r apps/android/app/build/outputs/apk/onDevice/debug/app-onDevice-debug.apk`: install Android on-device flavor APK to running emulator.

### Hot Reload (InjectionIII)
- Install: `brew install --cask injectioniii`
- Key views have `@ObserveInjection` + `.enableInjection()` wired up (ContentView, ConversationView, HeaderView, SessionSidebarView, MessageBubbleView).
- Debug builds include `-Xlinker -interposable` in linker flags.
- Run the app in simulator, open InjectionIII pointed at the project directory, then save any Swift file to see changes without relaunching.

## Coding Style & Naming Conventions
- Swift style follows standard Xcode defaults: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions.
- Kotlin style follows standard Android/Kotlin conventions: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members.
- Dark theme: pure `Color.black` backgrounds, `#00FF9C` accent, `SFMono-Regular` font throughout.
- Keep concurrency boundaries explicit (`actor`, `@MainActor`) and avoid cross-actor mutable state.
- Group iOS files by layer (`Views`, `Models`, `Bridge`) and Android files by module (`app/ui`, `app/state`, `core/*`).
- No repository-local SwiftLint/SwiftFormat config is currently committed; keep formatting consistent with existing files.

## Testing Guidelines
- iOS tests: prefer XCTest and create `Tests/CodexIOSTests/` with files named `*Tests.swift`.
- Android tests: place unit tests under `apps/android/app/src/test/java/`.
- iOS test command: `xcodebuild test` using the same project/scheme/destination pattern as build commands.
- Android test command: `gradle -p apps/android :app:testOnDeviceDebugUnitTest :app:testRemoteOnlyDebugUnitTest`.
- Keep `apps/android/docs/qa-matrix.md` updated when parity scope changes.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with optional scope (example: `bridge: retry initialize handshake`).
- PRs should include: purpose, key changes, verification steps (commands/device), and screenshots for UI changes.
- If project structure changes, include updates to `apps/ios/project.yml` and mention whether project regeneration was run.
