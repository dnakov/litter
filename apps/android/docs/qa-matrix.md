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

## Manual Matrix

| Area | onDevice flavor | remoteOnly flavor |
|---|---|---|
| App launch | App launches and can start local bridge-backed session | App launches and does not auto-start local bridge |
| Connect local/on-device | Success (`ServerConfig.local`) | Expected failure with clear "disabled" error |
| Connect remote server | Success | Success |
| Local transport drop | Reconnect and one-time reinitialize before next non-initialize RPC | N/A (local startup disabled) |
| Remote transport drop | Reconnect behavior via `BridgeRpcTransport` and resumed RPC notifications | Same |
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
