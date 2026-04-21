# Android QA Matrix

## Scope

This matrix covers backend-aware server selection, reconnect reliability, and startup-path parity for Android Codex/OpenCode flows.

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
| Connect Codex local/on-device | Success (`ServerConfig.local`) | Expected failure with clear "disabled" error |
| Connect Codex direct remote | Success | Success |
| Connect Codex over SSH | Success with SSH bootstrap, backend-aware status, and reconnect-safe server identity | Same |
| Connect OpenCode local HTTP | Success with base URL, directory scopes, and backend-aware workspace picker | Success with base URL, directory scopes, and backend-aware workspace picker |
| Connect OpenCode over Tailscale HTTPS | Discovery/manual row shows OpenCode + HTTPS/Tailscale + auth state before connect; connect succeeds with saved scopes | Same |
| Relaunch reconnect to saved OpenCode server | Saved server reconnects, rehydrates thread list for saved directory scopes, and keeps disconnected/reconnected state coherent in UI | Same |
| Relaunch reconnect to saved Codex server | Saved server reconnects with backend/transport labels preserved from the original connection path | Same |
| OpenCode prompt lifecycle | Thread list, read/resume, start thread in selected directory, async prompt streaming, interrupt, approval response, and model refresh all work through Rust runtime state | Same |
| SSH-discovered remote server | Prompts for SSH credentials, connects through SSH port forwarding, and never attempts `ws://host:22` directly | Same |
| Local transport drop | Reconnect and one-time reinitialize before next non-initialize RPC | N/A (local startup disabled) |
| Remote transport drop | Reconnect behavior via Rust `AppStore` updates and resumed RPC notifications | Same |
| Thread start/resume fallback sandbox | `workspace-write` with `danger-full-access` fallback when linux sandbox missing | Same |

## Suggested Smoke Steps

1. `onDeviceDebug`: connect local default server, start thread, send turn, toggle network off/on, send another turn.
2. `onDeviceDebug`: kill local bridge process (or force stop app), relaunch, confirm initialize and thread list recover.
3. `remoteOnlyDebug`: attempt local connect path, verify explicit disabled error; connect remote server and run thread/list + turn/start.
4. Both flavors: verify account read/login status refresh still updates UI after reconnect.
5. Start Codex local, Codex direct remote, and Codex over SSH; in each case verify the New Session flow starts with server choice, then workspace choice, and the selected server row shows backend + transport + status.
6. Start OpenCode with `litter-opencode-start`, inspect helper-managed credentials with `litter-opencode-creds`, then verify both manual local connect to `http://127.0.0.1:4187` and Tailscale discovery/manual connect to the published `https://<device>.ts.net:4187` endpoint when the device is on the same tailnet.
7. On both flavors, verify saved OpenCode credentials plus directory scope survive relaunch and reconnect to the same server, and that editing scopes forces a reconnect onto the updated scope list.
8. On both flavors, in the connected OpenCode directory, verify thread read/resume, new thread creation, async prompt streaming, interrupt, approval response, and model refresh.
9. With a large OpenCode model catalog, verify search, provider grouping, pin/unpin, recent models, default-model reset, and manual refresh all remain scoped to the selected server.

## Sidebar + Picker Parity Checklist (iOS + Android)

### Session Sidebar

- Sidebar stays unmounted while closed; local UI controls persist when reopened.
- Search + server filter + forks filter produce stable grouping and lineage chips.
- Opening/closing sidebar does not trigger excessive recomposition/signpost churn in idle state.

### Thread List Consistency

- Refresh (`thread/list`) prunes non-authoritative placeholder threads unless they are currently active.
- Notification-only placeholder rows disappear on next refresh once inactive.
- No regressions in thread switching, forking, or session search after placeholder pruning.

### Launch Flow

- New Session starts with an explicit server picker, not a combined server+directory sheet.
- Server rows show backend, transport, connection path, status, and last-used workspace hint.
- OpenCode rows show saved scope count and keep directory-scoped language explicit.
- Workspace step is backend-specific:
  - Codex: remote browse with breadcrumb + `Up one level`.
  - OpenCode: saved directory scopes first, with add/edit/remove.
- Primary action: one-tap `Continue in <last folder>` appears when recents exist.

### Appearance

- Chat wallpaper can be chosen from the photo library, persists across relaunch, and can be removed from Settings.
- Conversation screen and appearance preview both render the selected wallpaper instead of the fallback theme gradient.

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
