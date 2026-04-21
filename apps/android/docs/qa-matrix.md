# Android QA Matrix

## Scope

This matrix covers transport reliability and startup-path parity for Android websocket + bridge flows.

## Automated Regression Scaffolding

Run unit tests for both runtime flavors:

```bash
./gradlew :app:testOnDeviceDebugUnitTest
./gradlew :app:testRemoteOnlyDebugUnitTest
```

Current automated checks:

- `RuntimeFlavorConfigTest`
  - validates startup mode/build config parity (`ENABLE_ON_DEVICE_BRIDGE`, `RUNTIME_STARTUP_MODE`)
  - validates canonical app runtime transport declaration (`APP_RUNTIME_TRANSPORT`)
- `BridgeTransportReliabilityPolicyTest`
  - validates reconnect detection policy for healthy/stale websocket state
- `CodexRuntimeStartupPolicyTest`
  - validates startup toggle parsing and precedence logic
- `ThreadPlaceholderPrunePolicyTest`
  - validates placeholder prune-on-refresh behavior (including active-thread exemption)

## Manual Matrix

| Area | onDevice flavor | remoteOnly flavor |
|---|---|---|
| App launch | App launches and can start local bridge-backed session | App launches and does not auto-start local bridge |
| Connect local/on-device | Success (`ServerConfig.local`) | Expected failure with clear "disabled" error |
| Connect remote server | Success | Success |
| SSH-discovered remote server | Prompts for SSH credentials, connects through SSH port forwarding, and never attempts `ws://host:22` directly | Same |
| Local transport drop | Reconnect and one-time reinitialize before next non-initialize RPC | N/A (local startup disabled) |
| Remote transport drop | Reconnect behavior via Rust `AppStore` updates and resumed RPC notifications | Same |
| Thread start/resume fallback sandbox | `workspace-write` with `danger-full-access` fallback when linux sandbox missing | Same |

## Suggested Smoke Steps

1. `onDeviceDebug`: connect local default server, start thread, send turn, toggle network off/on, send another turn.
2. `onDeviceDebug`: kill local bridge process (or force stop app), relaunch, confirm initialize and thread list recover.
3. `remoteOnlyDebug`: attempt local connect path, verify explicit disabled error; connect remote server and run thread/list + turn/start.
4. Both flavors: verify account read/login status refresh still updates UI after reconnect.

## Sidebar + Picker Parity Checklist (iOS + Android)

### Session Sidebar

- Sidebar stays unmounted while closed; local UI controls persist when reopened.
- Search + server filter + forks filter produce stable grouping and lineage chips.
- Opening/closing sidebar does not trigger excessive recomposition/signpost churn in idle state.

### Thread List Consistency

- Refresh (`thread/list`) prunes non-authoritative placeholder threads unless they are currently active.
- Notification-only placeholder rows disappear on next refresh once inactive.
- No regressions in thread switching, forking, or session search after placeholder pruning.

### Directory Picker

- Primary action: one-tap `Continue in <last folder>` appears when recents exist.
- Top controls remain visible while list scrolls: connected server chip/status + search.
- Breadcrumb + `Up one level` navigation always reflects current path.
- Bottom CTA is sticky and mirrors path state: `Select <path>` (or disabled helper text).
- Error state exposes both `Retry` and `Change server`.
- `Clear recent directories` requires destructive confirmation.
- Back behavior parity:
  - Android: `Back` navigates up before dismissing sheet.
- iOS: dismiss is blocked while not at root; cancel navigates up first.

### Appearance

- Chat wallpaper can be chosen from the photo library, persists across relaunch, and can be removed from Settings.
- Conversation screen and appearance preview both render the selected wallpaper instead of the fallback theme gradient.

### Conversation Selection

- Settled assistant markdown supports long-press selection/copy.
- Reasoning text supports long-press selection/copy.
- Command output supports selection/copy and still scrolls vertically.
- Error text supports selection/copy.
- Code blocks support selection/copy and still scroll horizontally.
- Markdown links remain tappable after selection support changes.

## Home Dashboard Zoom + Swipe Reply Parity (mirrors iOS b96961b3 + 52ff299d)

Ported in parallel with the iOS "new ui" and "new ui stuff" commits. Each
item must render identically to the iOS `HomeDashboardView` on zoom-1/2/3/4
for the matching state.

| Feature | Check |
|---|---|
| Zoom toolbar button | Top-right of header cycles 1→2→3→4→3→2→1 with icon matching level (ViewQuilt→ViewList→ViewAgenda→ViewStream). Persists across app restart via `DashboardZoomPrefs` SharedPreferences. |
| Pinch-to-zoom | Pinch on home LazyColumn crosses level thresholds (`pinchAccumulator ± 0.4 → 1 level`), emits haptic on transition, does not steal single-finger vertical scroll. |
| Zoom 1 (scan) | Title + StatusDot only; no meta/body/chips. |
| Zoom 2 (glance) | + time · server · workspace meta line. Tool-activity label + pulsing dots appear only when `isActive && isToolCallRunning(hydratedItems)` — pure thinking falls through to server metadata. |
| Zoom 3 (read) | + modelBadgeLine (server icon + server + model + fork/subagent) with trailing inline stats, + user-message quote `>` prefix, + compact tool log (1 row), + response preview capped at 25% screen. |
| Zoom 4 (deep) | Tool log expands to 3 rows; response preview cap rises to 50% screen; preview scroll-anchors to bottom when overflowing. |
| Response preview crossfade | New assistant-block id flip triggers Crossfade on the preview; preserved on empty new-turn assistant items via `displayedAssistantMessage` walking back to last non-empty. |
| TurnStopwatchChip | Live 1Hz tick while turn active (end=null) via `produceState` + `delay(1000)`; static elapsed when ended. Format `<60s → "Xs"`, `<3600s → "Xm" or "XmYs"`. |
| Tool log grouping | Consecutive exploration commands (read/search/listFiles `HydratedCommandActionKind`) collapse into `⌕ Explored N files, M searches, K listings` summary row; other tool kinds render as single-line rows with `toolIconForName` glyph. |
| inlineStats chips | Turn count, tool count, diff `+N/-N`, TurnStopwatchChip, token % (warning tint ≥80%). Left text truncates first; chips stay pinned. |
| recentUserMessage | `>` chip prefix + FormattedText at `LitterFont.conversationBodyPointSize × textScale`. Only shown when message exists and differs from title. |
| StatusDot shimmer | Active state gets both the 800ms alpha pulse AND a 2s linear-gradient sweep overlay. |
| Home hydration | Home list calls `appModel.externalResumeThread(session.key)` — not `client.readThread` — so the server attaches a live listener and cards update without opening the thread. |
| Swipe reply | Right-swipe on home row reveals reply affordance (`SessionReplySwipe` via `SwipeableRow.leadingAction`); past commit threshold opens `QuickReplySheet` modal; send path resumes the thread before `startTurn` to avoid "thread cannot be found" on cold launches. Left-swipe reveals hide (trailingAction). |
| SavedProjectStore | Last-selected server + project persist across app restart via Rust `preferencesSetHomeSelection` / `HomeSelection`. Wired through `LitterApp.kt`. |
| StreamingMarkdownView bodySize | Optional `bodySize` parameter thread through to TextView font size; opt-in by response preview and by direct consumers that need parametric sizing. |

## Tool Call Card Parity Matrix (iOS + Android)

Renderer contract for this release:

- default collapsed for tool cards, except `failed` cards (default expanded)
- header order: icon, summary/title, spacer, status chip, optional duration chip, chevron
- section order: metadata KV, payload sections (`Command/Arguments/Result/Output/Action`), auxiliary sections (`Prompt/Targets/Progress`)
- parse miss fallback: legacy markdown rendering unchanged

| Tool kind | Summary rule | Status chip | Expected sections |
|---|---|---|---|
| Command Execution | stripped command + status/duration suffix | `inProgress`/`completed`/`failed`/`unknown` | Metadata, Command, Output (if present), Progress (if present) |
| Command Output | output label fallback (`Command Output`) when no command | usually `unknown` | Output text/code |
| File Change | first basename + `+N files` | normalized from `Status:` | Metadata, repeated `Change N` metadata + diff/text content |
| File Diff | first path basename when available, else `File Diff` | usually `unknown` | Diff panel |
| MCP Tool Call | `Tool:` value + status suffix/check | normalized from `Status:` | Metadata, Arguments/Result, Error/Progress as available |
| MCP Tool Progress | tool/status fallback or title | usually `unknown` unless merged into MCP call | Progress timeline text |
| Web Search | `Query:` value | usually `unknown` | Metadata, Action JSON |
| Collaboration | `Tool:` value fallback | normalized from `Status:` | Metadata, Prompt text, Targets list |
| Image View | basename from `Path:` | usually `unknown` | Metadata (`Path`) |

Status normalization parity:

- `inProgress`, `in progress`, `running`, `pending`, `started` -> in progress (amber)
- `completed`, `complete`, `success`, `ok`, `done` -> completed (green)
- `failed`, `failure`, `error`, `denied`, `cancelled`, `aborted` -> failed (red)
- anything else/missing -> unknown (neutral)
