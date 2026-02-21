# iOS TestFlight Checklist

1. Confirm `apps/ios/project.yml` bundle ID/version/build settings are correct.
2. Build/archive in Xcode from `apps/ios/Litter.xcodeproj`.
3. Upload archive via Xcode Organizer or `asc publish testflight`.
4. Validate processing in App Store Connect.
5. Add build to internal/external TestFlight groups.
6. Verify release notes and tester instructions.
7. Smoke test install + login/session/message flow.
