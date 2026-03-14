Summary

- Generative UI: the model can now render interactive widgets (diagrams, charts, interactive explainers) inline in conversations.
- Enable in Settings → Experimental Features → Generative UI, then start a new thread.
- Widgets support clickable nodes that send follow-up prompts, and an Expand button for fullscreen view with pinch-to-zoom.
- Widget history persists across session reloads.
- Sidebar animation no longer causes UI freezes on conversations with many messages.
- Scroll-to-bottom "Latest" button is now reliably tappable.
- Android: OpenCode mobile shell v2 with remote server support.

What to test

- Enable Generative UI in Settings → Experimental Features.
- Start a new thread and ask for a diagram (e.g. "explain how TCP works" or "how does a hash map work").
- Verify the widget renders inline with theme-appropriate colors.
- Tap the Expand button — should open fullscreen with scroll and pinch-to-zoom.
- Tap clickable nodes in diagrams — should send follow-up messages.
- Switch to another thread and back — widget should still be visible.
- Kill and relaunch the app, resume the thread — widget should reload from history.
- Scroll through long conversations with widgets — no freezing.
- Open/close sidebar — no freezing or jank.
- Tap the "Latest" button when scrolled up — should scroll to bottom.

Merged PRs

- PR #27: Generative UI widget system with inline rendering, experimental feature gate, widget persistence, sidebar perf fix.
- PR #26: "Latest" scroll-to-bottom button fix.
- PR #24: Android OpenCode mobile shell v2.
- PR #25: Theme system, appearance settings, semantic colors, rate limit fixes, adaptive app icon.
