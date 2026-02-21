# iOS + Android Monorepo Migration Plan

## Branch
- Working branch: `migration/ios-android-monorepo-exec`
- Base commit: `9df7e37`

## Progress
- [x] Phase 1: Introduced top-level `apps/`, `shared/`, and `tools` scaffolding.
- [x] Phase 2: Moved shared Rust bridge and Codex submodule paths.
- [x] Phase 3: Moved iOS app into `apps/ios` and revalidated build.
- [ ] Phase 4: Expand Android app into feature modules.
- [ ] Phase 5: Add Android Rust bridge/JNI integration.

## Goals
1. Keep iOS shipping while introducing Android native app support.
2. Share Rust/Codex integration once, consume from both platforms.
3. Keep third-party code explicit and version-pinned.
4. Minimize large refactors by migrating in checkpoints with build gates.

## Target Repository Layout
```text
litter/
├─ apps/
│  ├─ ios/
│  │  ├─ project.yml
│  │  ├─ Litter.xcodeproj
│  │  ├─ Sources/
│  │  ├─ Frameworks/
│  │  └─ scripts/
│  └─ android/
│     ├─ settings.gradle.kts
│     ├─ build.gradle.kts
│     ├─ gradle.properties
│     ├─ app/
│     ├─ core/
│     └─ feature/
├─ shared/
│  ├─ rust-bridge/
│  │  ├─ codex-bridge/
│  │  └─ include/
│  ├─ third_party/
│  │  └─ codex/
│  └─ protocol/
├─ tools/
│  ├─ scripts/
│  └─ ci/
├─ docs/
└─ .github/workflows/
```

## Current-to-Target Path Mapping
- `project.yml` -> `apps/ios/project.yml`
- `Litter.xcodeproj/` -> `apps/ios/Litter.xcodeproj/`
- `Sources/Litter/` -> `apps/ios/Sources/Litter/`
- `Frameworks/` -> `apps/ios/Frameworks/`
- `scripts/` -> `apps/ios/scripts/` (then extract shared scripts into `tools/scripts/`)
- `codex-bridge/` -> `shared/rust-bridge/codex-bridge/`
- `third_party/codex/` -> `shared/third_party/codex/`
- `patches/codex/` -> `shared/third_party/codex/patches/` or `tools/patches/codex/`

## Migration Phases

### Phase 0: Baseline + Safety
- Freeze current iOS baseline on branch.
- Capture build commands that must remain green:
  - `xcodegen generate`
  - `xcodebuild -project Litter.xcodeproj -scheme Litter -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- Add a migration tracking checklist in this doc (or project board).

Exit criteria:
- Baseline commands pass before any move.

### Phase 1: Introduce New Top-Level Structure (No Moves Yet)
- Create empty directories: `apps/`, `shared/`, `tools/`.
- Add placeholder Android Gradle files under `apps/android/`.
- Add README notes documenting intended layout and ownership.

Exit criteria:
- No behavior change; iOS build still passes.

### Phase 2: Move Shared Rust + Codex Source
- Move `codex-bridge/` to `shared/rust-bridge/codex-bridge/`.
- Move submodule path from `third_party/codex` to `shared/third_party/codex`.
- Update `.gitmodules` path and run:
  - `git submodule sync --recursive`
  - `git submodule update --init --recursive`
- Update Rust build scripts to reference new paths.

Files expected to change:
- `.gitmodules`
- `apps/ios/scripts/build-rust.sh` (after Phase 3 move)
- `apps/ios/scripts/sync-codex.sh` (after Phase 3 move)
- `README.md`

Exit criteria:
- Rust bridge builds successfully from new location.
- Submodule resolves at new path with same commit.

### Phase 3: Move iOS App Into `apps/ios`
- Move iOS files:
  - `project.yml`, `Litter.xcodeproj`, `Sources`, `Frameworks`, iOS scripts.
- Rewrite paths in `apps/ios/project.yml`:
  - `Sources/Litter/...` -> `apps/ios/Sources/Litter/...` or make paths relative to `apps/ios`.
- Update script relative paths after move.
- Regenerate Xcode project from new location.

Files expected to change:
- `apps/ios/project.yml`
- `apps/ios/scripts/*.sh`
- `Package.swift` (if kept at root, update local package paths)
- docs and build instructions

Exit criteria:
- iOS app builds from new location with equivalent output.

### Phase 4: Android Native Scaffold
- Create Android app at `apps/android/app` (Kotlin + Compose or XML).
- Add modules for shared Android concerns:
  - `apps/android/core/network`
  - `apps/android/core/bridge`
  - `apps/android/feature/{conversation,sessions,discovery}`
- Add baseline app shell mirroring iOS flows:
  - server discovery/connect
  - session list/resume/start
  - message stream view

Exit criteria:
- Android debug build passes (`./gradlew :app:assembleDebug`).

### Phase 5: Rust Bridge for Android
- Produce Android-compatible Rust artifacts from `shared/rust-bridge/codex-bridge`:
  - `aarch64-linux-android`
  - `armv7-linux-androideabi` (optional)
  - `x86_64-linux-android`
- Add JNI layer and package `.so` into Android module.
- Unify FFI API surface between iOS and Android.

Exit criteria:
- Android can start/stop the Codex bridge from app runtime.

### Phase 6: CI + Developer Workflows
- Split CI into platform lanes:
  - iOS build/test
  - Android build/test
  - Rust bridge build/test
- Add shared formatting/linting for Rust and shell scripts.
- Add cache strategy for submodule and Rust/Gradle artifacts.

Exit criteria:
- PR checks run per changed area and remain under acceptable time.

### Phase 7: Cleanup + Documentation
- Update root README with platform entry points.
- Add `docs/ios/` and `docs/android/` quickstarts.
- Add release checklists for TestFlight and Play internal track.

Exit criteria:
- New contributor can build both apps from docs only.

## Known Risks and Mitigations
1. Relative-path breakage after file moves.
- Mitigation: move one domain per phase and run build gate immediately.

2. Submodule path migration causing detached or missing state.
- Mitigation: move with `.gitmodules` update plus `submodule sync/update` in same commit.

3. Divergent platform features over time.
- Mitigation: keep protocol + Rust bridge contract in `shared/` and version changes explicitly.

4. Large-review churn from physical moves.
- Mitigation: separate pure moves from logic changes; use phase-specific commits.

## Proposed Commit Sequence
1. `repo: scaffold apps/shared/tools directories`
2. `shared: move codex submodule and rust bridge paths`
3. `ios: move project under apps/ios and fix build scripts`
4. `android: add native project scaffold`
5. `android: add rust bridge integration`
6. `ci: split ios/android/bridge pipelines`
7. `docs: refresh build and release guides`

## Immediate Next Execution Step
- Execute Phase 4: add Android feature modules (`core`, `feature/*`) and align architecture with iOS flows.
