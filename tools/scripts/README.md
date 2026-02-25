# Shared Scripts (Planned)

Cross-platform automation scripts will move here over time.

- `build-android-rust.sh`: builds Android Rust bridge JNI libs into `apps/android/core/bridge/src/main/jniLibs`.
- `deploy-android-ondevice.sh`: builds Rust JNI libs, assembles `onDeviceDebug`, installs on a target device (`--serial`/`ANDROID_SERIAL`), and launches the app.
- `switch-app-identity.sh`: switches local app IDs between `com.sigkitten.litter` and `com.<your-identifier>.litter` for Android+iOS (`--to your-identifier --identifier <name>`), with optional `--team-id` for iOS signing. For iOS it updates `apps/ios/project.yml` and regenerates `apps/ios/Litter.xcodeproj` via `xcodegen` (no direct `.xcodeproj` edits).
