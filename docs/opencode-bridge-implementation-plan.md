# OpenCode Bridge Implementation Plan

## Scope

This document covers the Rust implementation path for adding an `opencode-bridge` crate that lets Litter talk to an OpenCode server through the existing shared mobile runtime.

The repo crate is named `codex-mobile-client`; this document treats `codex-client-mobile` as shorthand for that existing crate. The goal is not to redesign the UI for multiple providers yet. The goal is to make OpenCode look like another backend behind `codex-mobile-client`, with no shared protocol parsing in Swift or Kotlin.

## Sources Checked

- OpenCode server docs: https://opencode.ai/docs/server/
- OpenCode SDK docs: https://opencode.ai/docs/sdk/
- OpenCode providers docs: https://opencode.ai/docs/providers/
- OpenCode generated SDK types: https://github.com/anomalyco/opencode/blob/dev/packages/sdk/js/src/gen/types.gen.ts
- OpenCode SSE route source: https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/opencode/src/server/routes/event.ts

## Current Litter Shape

- `codex-mobile-client` owns the single public UniFFI surface used by iOS and Android.
- `MobileClient` owns connected server sessions, event readers, health readers, the Rust `AppStore`, discovery, SSH, and post-connect warmup.
- `AppClient` exposes direct server operations to Swift/Kotlin.
- `AppStore` is the canonical runtime state owner.
- The current `ServerSession` path is Codex app-server specific: it connects over WebSocket or in-process transport, sends `codex-app-server-protocol` JSON-RPC requests, and receives typed Codex notifications.
- The UI should continue to observe `AppStore` snapshots and call `AppClient`; it should not learn OpenCode wire shapes.

## OpenCode Server Contract

OpenCode already has a client/server model. `opencode serve` starts a headless HTTP server, defaulting to `127.0.0.1:4096`, with optional mDNS and CORS settings. The server publishes an OpenAPI 3.1 spec at `/doc`.

Authentication has two layers:

- Server access can be protected with HTTP basic auth through `OPENCODE_SERVER_PASSWORD` and optional `OPENCODE_SERVER_USERNAME`.
- Provider credentials are managed through OpenCode provider/auth endpoints and local OpenCode config, not through the Codex account model.

The relevant HTTP API groups for the first bridge are:

- Health: `GET /global/health`
- Events: `GET /event`
- Project/path: `GET /project/current`, `GET /path`, `GET /vcs`
- Config/providers/models: `GET /config`, `GET /config/providers`, `GET /provider`, `GET /provider/auth`
- Sessions: `GET /session`, `POST /session`, `GET /session/status`, `GET /session/:id`, `PATCH /session/:id`, `DELETE /session/:id`, `GET /session/:id/children`, `POST /session/:id/fork`, `POST /session/:id/abort`
- Messages: `GET /session/:id/message`, `POST /session/:id/message`, `POST /session/:id/prompt_async`, `POST /session/:id/command`, `POST /session/:id/shell`
- Permissions: `POST /session/:id/permissions/:permissionID`
- Files: `GET /find`, `GET /find/file`, `GET /find/symbol`, `GET /file/content`, `GET /file/status`

The `/event` endpoint is an SSE stream. The implementation sends `server.connected` first, sends `server.heartbeat` periodically, and then forwards bus events. Generated SDK types include events such as `message.updated`, `message.part.updated`, `message.part.removed`, `permission.updated`, `permission.replied`, `session.status`, `session.idle`, `session.created`, `session.updated`, `session.deleted`, `session.diff`, and `session.error`.

## Target Architecture

Add `shared/rust-bridge/opencode-bridge/` as an internal Rust crate. It should not expose UniFFI directly.

`opencode-bridge` should own:

- OpenCode HTTP client setup, including base URL, server basic auth, timeouts, and request IDs/log context.
- Narrow OpenCode request and response types needed by mobile.
- SSE connection management and EventSource parsing.
- Mapping from OpenCode sessions, messages, parts, statuses, permissions, providers, and files into mobile-owned backend events/results.
- Capability reporting for unsupported or partially supported operations.
- Fixture-based tests for OpenCode payloads and event streams.

`codex-mobile-client` should remain the single public mobile facade. It should gain a backend boundary that can host either:

- the existing Codex app-server backend, or
- the new OpenCode backend from `opencode-bridge`.

The backend boundary should be internal to Rust. Swift/Kotlin should continue to work with `ServerBridge`, `AppClient`, `AppStore`, `DiscoveryBridge`, and `SshBridge` projections.

## Recommended Backend Boundary

Introduce a small Rust-only backend abstraction inside `codex-mobile-client` before wiring OpenCode. Keep it intentionally close to what the app already needs:

- connect and disconnect
- health stream
- backend event stream
- direct operation calls for the current `AppClient` methods
- capability report
- optional raw refresh methods used by post-connect warmup

The existing Codex app-server path becomes one backend implementation. `opencode-bridge` becomes another backend implementation. This avoids pretending OpenCode is literally a Codex JSON-RPC server and gives the bridge a clean place to report unsupported operations.

The store should receive the same mobile-level updates regardless of backend. If an operation succeeds, prefer authoritative refresh or event-driven updates over hand-patching UI state.

## Mapping Plan

### Connection

1. Add an OpenCode server config shape in Rust with `server_id`, display name, base URL, host, port, TLS flag, optional basic auth username/password, and project/worktree identity.
2. Connect by calling `GET /global/health`.
3. Subscribe to `GET /event` SSE.
4. Mark the server connected only after both health and SSE setup are healthy, or mark connected after health and degrade event state if SSE reconnect is still in progress.
5. Run post-connect warmup:
   - current project/path
   - session list
   - session status map
   - connected providers and model defaults

### Sessions To Threads

Map OpenCode `Session` to Litter `ThreadInfo`:

- `Session.id` -> `ThreadInfo.id`
- `Session.title` -> `ThreadInfo.title`
- `Session.directory` -> `ThreadInfo.cwd` and path fallback
- `Session.parentID` -> `ThreadInfo.parent_thread_id`
- `Session.time.created` and `Session.time.updated` -> thread timestamps
- `SessionStatus.idle` -> idle summary status
- `SessionStatus.busy` -> running summary status
- `SessionStatus.retry` -> running or error-adjacent status, with retry metadata kept internal until the UI has a typed projection

OpenCode session creation does not appear to accept a per-session working directory in the documented API. First implementation should treat the OpenCode server process directory as the backend scope. If `AppStartThreadRequest.cwd` differs from the server project directory, return a clear unsupported-capability error or require a separate OpenCode server connection for that directory.

### Messages To Conversation Items

Use `GET /session/:id/message` for hydration and `message.updated` / `message.part.updated` events for live updates.

Map OpenCode message info:

- `UserMessage` -> user-authored item
- `AssistantMessage` -> assistant item
- `AssistantMessage.error` -> error item or thread error state
- model provider/model fields -> thread model metadata where available
- token/cost/finish fields -> internal metadata first; add UI projections later only if needed

Map OpenCode parts:

- `text` -> assistant or user text content, with `delta` used for streaming when present
- `reasoning` -> reasoning section content
- `tool` -> tool call item with pending/running/completed/error states
- `file` -> attachment/reference item
- `patch` and `session.diff` -> diff metadata where the existing conversation/diff projections can represent it
- `step-start` and `step-finish` -> turn lifecycle boundaries
- `retry`, `compaction`, `agent`, and `subtask` -> preserve as typed internal events first; renderable projections can follow later

Unknown part types should be retained as raw JSON in Rust logs/tests and skipped or represented as a system metadata item, not parsed in Swift/Kotlin.

### Prompt And Turn Flow

For mobile's normal send-message flow:

1. Ensure a session exists. If starting a new thread, call `POST /session`.
2. Send user input through `POST /session/:id/prompt_async` so the UI can stream via SSE instead of waiting on the HTTP response.
3. Let `message.updated`, `message.part.updated`, `session.status`, and `session.idle` drive store updates.
4. After terminal events or after a reconnect, refresh `GET /session/:id/message` to reconcile any missed parts.

For a blocking command-style operation where the UI expects a completed response, `POST /session/:id/message` can be used later, but the first mobile path should prefer async plus SSE because it matches the existing streaming store model.

### Interrupt, Fork, Rename, Delete

- `interrupt_turn` maps to `POST /session/:id/abort`.
- `fork_thread` maps to `POST /session/:id/fork`; initially fork the whole session unless the UI supplies a message id later.
- `rename_thread` maps to `PATCH /session/:id` with title.
- `archive_thread` should not immediately map to `DELETE /session/:id` without product confirmation because OpenCode delete removes session data. First pass should expose delete only behind a deliberately named internal operation or report archive unsupported.

### Permissions

OpenCode emits `permission.updated` and accepts responses at `POST /session/:id/permissions/:permissionID`.

Map this to the existing pending approval flow:

- permission id -> pending approval id
- session id -> thread id
- permission title/type/pattern/metadata -> approval display fields
- response -> OpenCode permission response body

Keep `remember` support if the OpenCode response body accepts it for the relevant permission type. If not, ignore the mobile remember flag with a logged warning.

### Providers And Models

OpenCode supports many providers through AI SDK and Models.dev. The first bridge should avoid flooding the current mobile model picker.

Initial behavior:

- Fetch `GET /provider` or `GET /config/providers`.
- Flatten only connected providers by default.
- Include each provider's default model.
- Optionally include all models behind a Rust capability/config flag, not UI by default.
- Preserve provider id and model id separately internally, even when the mobile UI currently passes a single `model` string.

When sending a prompt, map mobile model strings into OpenCode's `{ providerID, modelID }` shape. If the model string has no provider component, resolve it through OpenCode defaults.

Provider login should be a later bridge phase. The first phase should support connecting to an already configured OpenCode server and reading provider/auth state.

### Files And Search

Map the current mobile file utilities to OpenCode file endpoints:

- fuzzy file search -> `GET /find/file`
- text search -> `GET /find`
- symbol search -> `GET /find/symbol`
- read file -> `GET /file/content`
- status -> `GET /file/status`

Directory browsing is not the same as Codex SSH shell browsing. For OpenCode, prefer documented file endpoints. Keep remote shell directory browsing disabled unless a later bridge phase maps it explicitly.

### Unsupported In First Pass

Do not try to support these in the first bridge slice:

- realtime voice
- Codex account/rate-limit semantics
- Codex IPC follower/stream optimization
- arbitrary per-thread cwd if OpenCode server does not support it
- dynamic tools unless OpenCode exposes an equivalent shape that can be mapped cleanly
- full provider login and OAuth UX
- TUI control endpoints
- huge all-provider model picker behavior

Expose unsupported operations through backend capabilities and clear Rust errors so the UI can keep existing controls disabled or hidden without parsing OpenCode details.

## Implementation Steps

### Phase 1: Contract And Crate

1. Add `opencode-bridge` to the Rust workspace.
2. Add dependencies for HTTP JSON and SSE parsing. Prefer reusing existing workspace dependencies where possible.
3. Create narrow handwritten OpenCode types for the endpoints and events used by mobile. Do not generate a broad Rust SDK as part of the first pass.
4. Add fixture JSON for sessions, messages, parts, permissions, providers, and SSE records.
5. Add unit tests that deserialize fixtures and reject malformed/unknown shapes gracefully.

### Phase 2: REST Client

1. Implement health, project/path, session list/status/detail/messages, prompt async, abort, fork, rename, providers, and permission response calls.
2. Normalize HTTP errors into bridge errors with status code, endpoint, retryability, and safe message text.
3. Add basic auth header support for protected OpenCode servers.
4. Keep provider credentials out of Litter storage for this phase; OpenCode remains responsible for provider auth storage.

### Phase 3: SSE Reader

1. Connect to `/event`.
2. Parse EventSource data records as OpenCode events.
3. Treat `server.connected` as stream readiness.
4. Ignore `server.heartbeat` except for liveness.
5. Reconnect with backoff after network failures.
6. On reconnect, refresh session list/status and any open thread messages.
7. Stop the stream on server dispose or explicit disconnect.

### Phase 4: Mapping Layer

1. Convert OpenCode sessions/statuses into mobile thread summaries.
2. Convert OpenCode messages/parts into hydrated conversation state inputs.
3. Convert OpenCode permission events into pending approvals.
4. Convert provider/model responses into mobile model projections.
5. Preserve unknown event and part payloads in Rust logs and tests.

### Phase 5: `codex-mobile-client` Integration

1. Add an internal backend abstraction for connected servers.
2. Move the existing Codex app-server path behind that abstraction without changing UniFFI.
3. Add an OpenCode backend that delegates HTTP/SSE work to `opencode-bridge`.
4. Add `connect_opencode` on the Rust side, then expose only the minimal UniFFI connect method needed by the platform discovery/manual connection flows.
5. Reuse existing `AppStore` updates and snapshots wherever possible.
6. Keep Swift/Kotlin changes limited to connection configuration and capability-driven UI state.

### Phase 6: Tests And Validation

1. Unit-test all OpenCode deserialization and mapping functions with fixtures.
2. Unit-test backend capability behavior for unsupported operations.
3. Add store/reducer tests proving OpenCode events update the same snapshots the UI already observes.
4. Add a fake HTTP/SSE server test for connect, list sessions, send prompt async, stream parts, permission response, and reconnect.
5. Add an ignored/manual integration test against a real `opencode serve` instance.
6. Run `cargo test` for `opencode-bridge` and `codex-mobile-client`.

## Acceptance Criteria

- Rust can connect to a running OpenCode server with optional basic auth.
- Rust can list OpenCode sessions as Litter threads.
- Rust can read a session's message history.
- Rust can send a prompt asynchronously and update the store from SSE events.
- Rust can stream text, reasoning, and basic tool state updates into existing conversation projections.
- Rust can abort a running OpenCode session.
- Rust can surface and answer OpenCode permission requests through the existing approval flow.
- Rust can expose connected-provider default models without dumping every OpenCode model into the current picker.
- Swift and Kotlin do not parse OpenCode JSON or SSE payloads.

## Open Questions

- Should an OpenCode server connection represent one project directory, with separate connections for separate working directories?
- Should mobile expose OpenCode server basic auth credentials in the existing server config storage, or should that wait for the multi-provider UI pass?
- Which OpenCode delete/share/summarize/revert actions should map to existing mobile actions, and which should stay hidden until there is matching product UX?
- Should OpenCode agents map to Litter collaboration modes, or remain backend-specific metadata until the UI supports provider-specific agents?
- Should the bridge flatten `provider/model` into the current model string field, or should `codex-mobile-client` add a provider-aware Rust model type before OpenCode ships?
- How much raw OpenCode tool metadata should be preserved for future rendering without exposing unstable provider-specific JSON to the UI?

## Recommended First Slice

Build the first slice around an already configured local OpenCode server:

1. Manual connect to `http://host:4096`.
2. Health plus SSE connection.
3. Session list and message hydration.
4. Prompt async with text/reasoning/tool streaming.
5. Abort and permission response.
6. Connected-provider default model list.

This is enough to prove the bridge shape while leaving multi-provider selection, OpenCode login UX, huge model lists, and advanced OpenCode-specific actions for separate product decisions.
