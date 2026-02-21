# Repository Guidelines

## Project Structure & Module Organization
- `Sources/CodexIOS/` contains the iOS app code.
- `Sources/CodexIOS/Views/` holds SwiftUI screens, `Models/` contains app state/session logic, and `Bridge/` contains JSON-RPC and C FFI bridge code.
- `shared/rust-bridge/codex-bridge/` is the Rust static library (`libcodex_bridge.a`) exposed through `shared/rust-bridge/codex-bridge/include/codex_bridge.h`.
- `Frameworks/` stores vendored XCFrameworks (`codex_bridge.xcframework` and `ios_system/*`).
- `project.yml` is the source of truth for project generation; regenerate `CodexIOS.xcodeproj` instead of hand-editing project files.

## Architecture
- **Root layout:** `ContentView` uses a `ZStack` with a persistent `HeaderView`, main content area, and a `SidebarOverlay` that slides from the left.
- **State management:** `ConversationStore` (ObservableObject) manages WebSocket connection, JSON-RPC calls, and message state. `AppState` (ObservableObject) manages UI state (sidebar, server, model/reasoning selection).
- **Server connection flow:** `DiscoveryView` (presented as a sheet) discovers and connects to a server. After connecting, the sidebar opens showing all sessions. Directory selection happens only when starting a new session via `DirectoryPickerView`.
- **Session management:** The sidebar (`SessionSidebarView`) lists all sessions from `thread/list` RPC. Tapping resumes via `thread/resume`. "New Session" opens a directory picker, then calls `thread/start`.
- **Model selection:** Models are fetched dynamically from the app-server via `model/list` RPC. The header displays a ChatGPT-style model selector. Model and reasoning effort are passed per-turn via `turn/start` params.
- **Message rendering:** `MessageBubbleView` renders user messages as plain text bubbles, assistant messages via MarkdownUI with custom dark themes (`.codex`/`.codexSystem`), and system messages in styled boxes. Reasoning messages use an unboxed italic layout with a brain icon. Code blocks use `CodeBlockView` with language labels and copy buttons. Base64 images in messages are decoded and displayed inline.

## Dependencies (SPM via project.yml)
- **Citadel** — SSH client for remote server connections.
- **MarkdownUI** — Renders Markdown in assistant/system messages with custom theming.
- **Inject** — Hot reload support for simulator development (Debug builds only).

## Build, Test, and Development Commands
- `./scripts/download-ios-system.sh`: download required `ios_system` XCFrameworks.
- `./scripts/build-rust.sh`: cross-compile Rust bridge from `shared/rust-bridge/codex-bridge` for device/simulator and rebuild `Frameworks/codex_bridge.xcframework`.
- `xcodegen generate`: regenerate `CodexIOS.xcodeproj` after changing `project.yml` or adding/removing files.
- `open CodexIOS.xcodeproj`: open and run from Xcode.
- `xcodebuild -project CodexIOS.xcodeproj -scheme CodexIOS -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`: CI-friendly local build.

### Hot Reload (InjectionIII)
- Install: `brew install --cask injectioniii`
- Key views have `@ObserveInjection` + `.enableInjection()` wired up (ContentView, ConversationView, HeaderView, SessionSidebarView, MessageBubbleView).
- Debug builds include `-Xlinker -interposable` in linker flags.
- Run the app in simulator, open InjectionIII pointed at the project directory, then save any Swift file to see changes without relaunching.

## Coding Style & Naming Conventions
- Swift style follows standard Xcode defaults: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions.
- Dark theme: pure `Color.black` backgrounds, `#00FF9C` accent, `SFMono-Regular` font throughout.
- Keep concurrency boundaries explicit (`actor`, `@MainActor`) and avoid cross-actor mutable state.
- Group new files by layer (`Views`, `Models`, `Bridge`) and keep feature-specific logic close to its UI entry point.
- No repository-local SwiftLint/SwiftFormat config is currently committed; keep formatting consistent with existing files.

## Testing Guidelines
- There is currently no committed test target in this snapshot.
- For new tests, prefer XCTest and create `Tests/CodexIOSTests/` with files named `*Tests.swift`.
- Run tests with `xcodebuild test` using the same project/scheme/destination pattern as build commands.
- At minimum, include a manual smoke test note for connection flow, auth, and message streaming when tests are not yet automated.

## Commit & Pull Request Guidelines
- Use concise, imperative commit subjects with optional scope (example: `bridge: retry initialize handshake`).
- PRs should include: purpose, key changes, verification steps (commands/device), and screenshots for UI changes.
- If project structure changes, include updates to `project.yml` and mention whether `xcodegen generate` was run.
