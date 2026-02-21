# Android Play Internal Checklist

1. Confirm `applicationId`, versionCode, and versionName in `apps/android/app/build.gradle.kts`.
2. Build signed release artifact (`.aab`).
3. Upload to Google Play Console internal testing track.
4. Add tester list/groups.
5. Verify release notes and rollout settings.
6. Install from Play internal track and smoke test core flows.
