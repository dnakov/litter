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
