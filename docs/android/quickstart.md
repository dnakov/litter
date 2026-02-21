# Android Quickstart

## Prerequisites
- Java 17
- Android SDK (API 35 + build-tools 35.0.0)
- Gradle 8.x
- Optional Rust bridge prerequisites:
  - Rust toolchain
  - Android NDK (`ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`)
  - `cargo-ndk` (`cargo install cargo-ndk`)

## Build Steps
1. Build Android app:
   - `gradle -p apps/android :app:assembleDebug`
2. Build Rust JNI bridge libs (optional, for on-device bridge runtime):
   - `./tools/scripts/build-android-rust.sh`

## Modules
- `:app`
- `:core:network`
- `:core:bridge`
- `:feature:discovery`
- `:feature:sessions`
- `:feature:conversation`
