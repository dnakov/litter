Summary

- Added expand button to open composer full screen
- Fixed persistent LiveViews
- Fixed subagent names not showing
- Fixed a deserialization error that prevented some threads from loading after syncing with the latest Codex runtime
- Composer autocorrect/smart quotes/spell check now follow iPhone Settings
- Fixed inline code in rendered messages showing larger than body text

What to test

- Inline code rendering: open a conversation where the assistant responded with inline backtick code (e.g. a file path like `apps/ios/...`). In the rendered message bubble, the code should appear at the same visual size as the surrounding body text — not visibly larger. Try both mono and system font modes in Appearance.
- Composer keyboard behavior: go to Settings → General → Keyboard and toggle Auto-Correction, Check Spelling, Smart Punctuation, and Auto-Capitalization. The conversation and home composers should match those toggles (autocorrect suggestions, red spelling underlines, and `"` → `"` / `--` → `—` conversion should all follow the system setting).
- Thread loading: connect to a server running the updated Codex runtime, open the thread list, and resume existing threads. They should load without errors, and `thread/read` should succeed for threads whose metadata now includes the new approval/sandbox fields.
