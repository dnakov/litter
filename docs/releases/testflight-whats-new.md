Summary

- Theme system with 20+ VS Code-inspired themes, adaptive app icon (light/dark/liquid glass), and Live Activity theming.
- Fixed semantic colors (success/warning/danger) to stay consistent across themes.
- Rate limit indicators now correctly show remaining quota instead of used.
- Bigger app icon with iOS 18+ dark/tinted appearance variants.
- SSH bootstrap now resolves `codex` through a real login shell.
- Voice transcription with mic button and waveform in the composer.

What to test

- Switch themes in Settings → Appearance and verify the preview updates live without dismissing the screen.
- Check the app icon adapts to light/dark mode (Settings → Home Screen → Automatic) and liquid glass on iOS 26.
- Verify rate-limit badges show remaining quota (100 = full, 0 = exhausted) with correct color coding.
- Confirm success/warning/danger colors stay green/amber/red regardless of selected theme.
- Check Live Activity lock screen card uses theme-appropriate colors in both light and dark mode.
- Try voice transcription, SSH connections, and discovery flows still work.

Merged PRs

- PR #25: Theme system, appearance settings, semantic colors, rate limit fixes, adaptive app icon.
- PR #22: SSH bootstrap via login shell.
- PR #21: Voice transcription with mic button and waveform.
- PR #20: Rate-limit indicators and context badge placement.
- PR #19: Light mode, font family setting, and code block scaling.
