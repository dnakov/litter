# OpenCode Bridge Implementation Plan

## Scope

This document covers the Rust implementation path for adding an `opencode-bridge` crate that lets Litter talk to an OpenCode server through the existing shared mobile runtime.

The repo crate is named `codex-mobile-client`; this document treats `codex-client-mobile` as shorthand for that existing crate. The goal is not to redesign the UI for multiple providers yet. The goal is to make OpenCode look like another backend behind `codex-mobile-client`, with no shared protocol parsing in Swift or Kotlin.

Pi / `pi-mono` support is expected later, but it is not part of this OpenCode slice. The backend boundary introduced for OpenCode should leave room for a future `pi-bridge` adapter without forcing Pi's subprocess/JSONL RPC model through OpenCode's HTTP/SSE bridge.

## Sources Checked

- OpenCode server docs: https://opencode.ai/docs/server/
- OpenCode SDK docs: https://opencode.ai/docs/sdk/
- OpenCode providers docs: https://opencode.ai/docs/providers/
- OpenCode generated SDK types: https://github.com/anomalyco/opencode/blob/dev/packages/sdk/js/src/gen/types.gen.ts
- Local OpenCode checkout: `/Users/franklin/Development/OpenSource/opencode`
- OpenCode instance middleware: `packages/opencode/src/server/instance/middleware.ts`
- OpenCode session routes: `packages/opencode/src/server/instance/session.ts`
- OpenCode instance event route: `packages/opencode/src/server/instance/event.ts`
- OpenCode global event route: `packages/opencode/src/server/instance/global.ts`
- OpenCode SDK directory rewriting: `packages/sdk/js/src/client.ts` and `packages/sdk/js/src/v2/client.ts`
- Pi mono repo: https://github.com/badlogic/pi-mono
- Pi coding-agent README and RPC/session docs: `packages/coding-agent/README.md`, `packages/coding-agent/docs/rpc.md`, `packages/coding-agent/docs/session.md`

## Current Litter Shape

- `codex-mobile-client` owns the single public UniFFI surface used by iOS and Android.
- `MobileClient` owns connected server sessions, event readers, health readers, the Rust `AppStore`, discovery, SSH, and post-connect warmup.
- `AppClient` exposes direct server operations to Swift/Kotlin.
- `AppStore` is the canonical runtime state owner.
- The current `ServerSession` path is Codex app-server specific: it connects over WebSocket or in-process transport, sends `codex-app-server-protocol` JSON-RPC requests, and receives typed Codex notifications.
- The UI should continue to observe `AppStore` snapshots and call `AppClient`; it should not learn OpenCode wire shapes.

## OpenCode Server Contract

OpenCode already has a client/server model. For local repo work and manual validation in this repo, start it through the shell helper alias `litter-opencode-start` from `~/.zshrc`. That alias runs the repo-local `./opencode-start` helper in tmux, which wraps `opencode serve`, enables HTTP basic auth, defaults to port `4187`, and when Tailscale is available also publishes the localhost-only server through `tailscale serve` on the same port. Use `litter-opencode-status`, `litter-opencode-stop`, and `litter-opencode-creds` alongside it when testing so the server process, listener state, and helper-managed basic auth credentials stay aligned. Raw `opencode serve` still exists upstream, but repo testing should use the Litter helper path. The server publishes an OpenAPI 3.1 spec at `/doc`.

Authentication has two layers:

- Server access can be protected with HTTP basic auth through `OPENCODE_SERVER_PASSWORD` and optional `OPENCODE_SERVER_USERNAME`.
- Provider credentials are managed through OpenCode provider/auth endpoints and local OpenCode config, not through the Codex account model.

The relevant HTTP API groups for the first bridge are:

- Health: `GET /global/health`
- Events: `GET /event`, with `GET /global/event` available for cross-directory event fanout
- Project/path: `GET /project/current`, `GET /path`, `GET /vcs`
- Config/providers/models: `GET /config`, `GET /config/providers`, `GET /provider`, `GET /provider/auth`
- Sessions: `GET /session`, `POST /session`, `GET /session/status`, `GET /session/:id`, `PATCH /session/:id`, `DELETE /session/:id`, `GET /session/:id/children`, `POST /session/:id/fork`, `POST /session/:id/abort`
- Messages: `GET /session/:id/message`, `POST /session/:id/message`, `POST /session/:id/prompt_async`, `POST /session/:id/command`, `POST /session/:id/shell`
- Permissions: `POST /session/:id/permissions/:permissionID`
- Files: `GET /find`, `GET /find/file`, `GET /find/symbol`, `GET /file/content`, `GET /file/status`

OpenCode supports directory-scoped server operations. The server middleware selects an instance from the `directory` query parameter or `x-opencode-directory` header before the route handler runs, falling back to the OpenCode server process directory. `POST /session?directory=<encoded path>` creates a session whose `Session.directory` is that resolved directory. Subsequent session, message, prompt, permission, file, provider, and event calls should include the same directory context unless the bridge is deliberately using global endpoints. The generated JavaScript SDK already models this by accepting `directory` on session operations and by rewriting `x-opencode-directory` into query parameters for GET/HEAD requests.

The `/event` endpoint is an instance-scoped SSE stream. With `?directory=<encoded path>`, it sends `server.connected` first, sends `server.heartbeat` periodically, and then forwards bus events for that directory instance. `GET /global/event` emits an envelope with `directory`, `project`, optional `workspace`, and `payload`; this is useful if Litter wants one OpenCode server connection to observe many directories.

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

The boundary should be provider-neutral enough for a later `shared/rust-bridge/pi-bridge/` crate. Pi should be a separate bridge crate because it uses a different transport and lifecycle: `pi --mode rpc` speaks strict JSONL over stdin/stdout and has process/session-file concerns, while OpenCode is a long-running HTTP/SSE server. The shared code should be the normalized backend contract in `codex-mobile-client`, not a single generic protocol crate that tries to hide those transport differences.

## Recommended Backend Boundary

Introduce a small Rust-only backend abstraction inside `codex-mobile-client` before wiring OpenCode. Keep it intentionally close to what the app already needs:

- connect and disconnect
- health stream
- backend event stream
- direct operation calls for the current `AppClient` methods
- capability report
- optional raw refresh methods used by post-connect warmup

The existing Codex app-server path becomes one backend implementation. `opencode-bridge` becomes another backend implementation. A future `pi-bridge` should become a third implementation. This avoids pretending OpenCode is literally a Codex JSON-RPC server and keeps Pi from being squeezed through OpenCode-specific HTTP/SSE assumptions.

Thread identity should allow backend-specific scope:

- Codex app-server: `(server_id, thread_id)`
- OpenCode: `(server_id, directory, session_id)`
- Pi later: likely `(server_id or process_id, directory, session_id)`

The store should receive the same mobile-level updates regardless of backend. If an operation succeeds, prefer authoritative refresh or event-driven updates over hand-patching UI state.

## Mapping Plan

### Connection

1. Add an OpenCode server config shape in Rust with `server_id`, display name, base URL, host, port, TLS flag, optional basic auth username/password, and known directory scopes.
2. Connect by calling `GET /global/health`.
3. Subscribe either to `GET /event?directory=<encoded cwd>` per active directory or to `GET /global/event` once and route envelopes by `directory`.
4. Mark the server connected only after both health and SSE setup are healthy, or mark connected after health and degrade event state if SSE reconnect is still in progress.
5. Run post-connect warmup:
   - current project/path per directory scope
   - session list per directory scope, or global/experimental session list later
   - session status map
   - connected providers and model defaults

For OpenCode, the working directory is request context. Every request created from a Litter thread key should include that thread's `directory` as a query parameter or `x-opencode-directory` header. Do not rely on session id alone to restore cwd.

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

OpenCode supports per-thread cwd through request-scoped directory context. When starting a new thread, call `POST /session?directory=<encoded cwd>` and store the returned `Session.directory` in the mobile thread key. If `AppStartThreadRequest.cwd` is absent, use the current selected directory for that OpenCode server. If the cwd is remote or inaccessible from the OpenCode server process, return a clear capability error.

For listing sessions, the first implementation should list per known directory with `GET /session?directory=<encoded cwd>`. A later pass can use `GET /experimental/session` for a broader cross-project session browser if product UX wants it.

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

1. Ensure a session exists. If starting a new thread, call `POST /session?directory=<encoded cwd>`.
2. Send user input through `POST /session/:id/prompt_async?directory=<encoded cwd>` so the UI can stream via SSE instead of waiting on the HTTP response.
3. Let `message.updated`, `message.part.updated`, `session.status`, and `session.idle` drive store updates.
4. After terminal events or after a reconnect, refresh `GET /session/:id/message?directory=<encoded cwd>` to reconcile any missed parts.

For a blocking command-style operation where the UI expects a completed response, `POST /session/:id/message` can be used later, but the first mobile path should prefer async plus SSE because it matches the existing streaming store model.

### Interrupt, Fork, Rename, Delete

- `interrupt_turn` maps to `POST /session/:id/abort`.
- `fork_thread` maps to `POST /session/:id/fork`; initially fork the whole session unless the UI supplies a message id later.
- `rename_thread` maps to `PATCH /session/:id` with title.
- `archive_thread` should not immediately map to `DELETE /session/:id` without product confirmation because OpenCode delete removes session data. First pass should expose delete only behind a deliberately named internal operation or report archive unsupported.

All of these calls should include the thread directory context. Forked sessions should inherit the source session's directory unless the UI explicitly supports a cross-directory fork later.

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

For OpenCode, prefer documented file endpoints with the thread directory context. Directory browsing can use `GET /file?path=<path>&directory=<encoded cwd>` for paths inside the OpenCode project/worktree boundary. Keep arbitrary remote shell directory browsing disabled unless a later bridge phase maps it explicitly.

### Future Pi Compatibility

Pi support should be planned as a later `pi-bridge` crate, not as extra code inside `opencode-bridge`.

The backend abstraction added for OpenCode should account for Pi's likely shape:

- transport is subprocess JSONL RPC over stdin/stdout, not HTTP/SSE
- connection health is process liveness plus RPC state, not `GET /global/health`
- event stream is stdout JSONL events, not EventSource records
- session identity likely includes a directory and Pi session id
- provider auth remains Pi-owned in the first pass
- approvals may be unsupported or extension-driven, not OpenCode permission endpoints

Do not add Pi APIs in this document's implementation phases. The only OpenCode requirement is to keep normalized backend events, capabilities, thread identity, and store integration broad enough that a later `pi-bridge` can plug in without changing Swift/Kotlin.

### Unsupported In First Pass

Do not try to support these in the first bridge slice:

- realtime voice
- Codex account/rate-limit semantics
- Codex IPC follower/stream optimization
- dynamic tools unless OpenCode exposes an equivalent shape that can be mapped cleanly
- full provider login and OAuth UX
- TUI control endpoints
- huge all-provider model picker behavior
- cross-directory fork/move semantics
- remote filesystem browsing outside OpenCode's project/worktree boundary

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
4. Add directory-context injection to every OpenCode request that needs it. Prefer an explicit `directory` field on internal request types rather than hidden global client state.
5. Keep provider credentials out of Litter storage for this phase; OpenCode remains responsible for provider auth storage.

### Phase 3: SSE Reader

1. Connect to `/event?directory=<encoded cwd>` per active directory for the first slice, or use `/global/event` if cross-directory fanout is implemented immediately.
2. Parse EventSource data records as OpenCode events.
3. Treat `server.connected` as stream readiness.
4. Ignore `server.heartbeat` except for liveness.
5. Reconnect with backoff after network failures.
6. On reconnect, refresh session list/status and any open thread messages.
7. Stop the stream on server dispose or explicit disconnect.
8. If using `/global/event`, route events by envelope `directory` before mapping them into mobile thread updates.

### Phase 4: Mapping Layer

1. Convert OpenCode sessions/statuses into mobile thread summaries.
2. Convert OpenCode messages/parts into hydrated conversation state inputs.
3. Convert OpenCode permission events into pending approvals.
4. Convert provider/model responses into mobile model projections.
5. Preserve directory in thread keys and route event updates through `(server_id, directory, session_id)`.
6. Preserve unknown event and part payloads in Rust logs and tests.

### Phase 5: `codex-mobile-client` Integration

1. Add an internal backend abstraction for connected servers.
2. Move the existing Codex app-server path behind that abstraction without changing UniFFI.
3. Add an OpenCode backend that delegates HTTP/SSE work to `opencode-bridge`.
4. Add `connect_opencode` on the Rust side, then expose only the minimal UniFFI connect method needed by the platform discovery/manual connection flows.
5. Make backend thread identity explicit enough for OpenCode directory-scoped sessions and future Pi directory-scoped sessions.
6. Reuse existing `AppStore` updates and snapshots wherever possible.
7. Keep Swift/Kotlin changes limited to connection configuration and capability-driven UI state.
8. Do not expose Pi-specific APIs yet; only keep the Rust backend boundary ready for a later `pi-bridge`.

#### Phase 5 Goal

Make `codex-mobile-client` backend-aware so the existing mobile facade can host both:

- the current Codex app-server transport path
- the new OpenCode HTTP/SSE path backed by `opencode-bridge`

without teaching Swift/Kotlin any OpenCode transport, event, or payload shapes.

At the end of Phase 5, OpenCode should be able to:

- connect as a first-class mobile server
- hydrate threads into the existing `AppStore` snapshot model
- stream conversation updates into the existing conversation projections
- surface pending approvals through the existing approval state
- expose connected-provider model choices through the existing mobile-facing model path

while Codex app-server behavior stays unchanged.

#### Explicit Non-Goals For Phase 5

- no new public multi-backend UI redesign
- no OpenCode-specific rendering logic in Swift/Kotlin
- no provider auth write flows or OAuth login flows
- no Pi backend implementation
- no broad UniFFI surface expansion beyond the minimum connect/config path needed for OpenCode
- no full cross-directory global session browser unless required by the chosen thread list path

#### Recommended Direction

Do the Phase 5 work inside `codex-mobile-client` as a Rust-only backend integration pass.

The important design choice is:

- `opencode-bridge` owns transport and mapping semantics
- `codex-mobile-client` owns backend selection, store updates, lifecycle, and UniFFI exposure
- store/reducer code should receive backend-neutral mobile state inputs, not raw OpenCode payloads

That keeps OpenCode-specific protocol handling out of the store and out of the native platforms.

#### Main Integration Constraints

The current `codex-mobile-client` shape is still Codex-specific in a few important places:

- connected sessions are stored as `HashMap<String, Arc<ServerSession>>`
- thread identity is still `ThreadKey { server_id, thread_id }`
- post-connect warmup assumes Codex account + thread RPCs
- event readers assume Codex notifications or Codex IPC followers
- `AppClient` methods are still largely Codex JSON-RPC shaped

Phase 5 needs to introduce the backend boundary without breaking that existing path.

#### Phase 5 Implementation Plan

1. Define a Rust-only backend kind and server runtime abstraction
   Add an internal abstraction in `codex-mobile-client` for a connected backend runtime. It should cover:
   - connect / disconnect
   - health updates
   - event stream hookup
   - post-connect warmup
   - direct operations needed by `AppClient`
   - capability reporting

   This should stay Rust-only at first.

2. Separate server identity from transport implementation
   Introduce a backend-aware server/session container so `MobileClient` no longer assumes every connected server is a `ServerSession`.
   The container should be able to hold:
   - Codex app-server runtime state
   - OpenCode runtime state

   Keep the external `server_id` stable.

3. Make thread identity backend-aware
   Replace the current implicit `(server_id, thread_id)` assumption with a backend-aware internal thread identity model that can represent:
   - Codex: `(server_id, thread_id)`
   - OpenCode: `(server_id, directory, session_id)`

   If the public `ThreadKey` stays unchanged for one transition step, the backend-specific identity still needs to exist internally and losslessly.

4. Add backend-neutral store input types
   Define narrow `codex-mobile-client` input types for:
   - thread summary upserts/removals
   - conversation hydration snapshots
   - conversation deltas
   - approval upserts/resolutions
   - model list projections
   - server capability updates

   These should be the seam between backends and the reducer/store layer.

5. Route Codex app-server through the new boundary first
   Before plugging in OpenCode, move the current Codex session lifecycle behind the backend abstraction.
   This is the safety step that proves the boundary is viable without changing behavior.

6. Add an OpenCode backend runtime
   Create an OpenCode backend implementation that uses:
   - `OpenCodeClient` for REST
   - `OpenCodeEventStreamClient` for SSE
   - Phase 4 mapping outputs for normalization

   This backend should own:
   - OpenCode connection config
   - directory-scoped event stream setup
   - initial warmup
   - mapping of live updates into backend-neutral store inputs

7. Define OpenCode post-connect warmup
   The OpenCode warmup path should fetch and map:
   - health
   - session list for known directory scopes
   - session statuses for those scopes
   - hydrated messages for any active/restored thread when needed
   - connected provider/default model projections

   Do not run Codex account sync for OpenCode.

8. Add OpenCode-backed implementations for the required `AppClient` operations
   Implement the subset of direct operations needed for parity with the current mobile workflow:
   - connect
   - list/resume/read thread equivalents
   - start thread
   - send prompt / stream turn
   - interrupt
   - rename
   - fork if supported by product path
   - permission response
   - model listing

   Unsupported operations should surface through backend capabilities and clear Rust errors rather than partial native hacks.

9. Add minimal UniFFI exposure for OpenCode connect/config
   Expose only the minimal connect path needed by platform discovery/manual connection flows, for example:
   - server id
   - display name
   - base URL / host / port
   - TLS flag if needed
   - optional basic auth username/password
   - one or more directory scopes

   Keep the rest of the OpenCode behavior behind the existing `AppClient` and `AppStore` surfaces.

10. Preserve platform parity
    Because all of this lives in shared Rust, both iOS and Android should pick up the same OpenCode behavior in the same pass. Any platform-specific follow-up should be limited to connect/config UI affordances.

#### Recommended Implementation Order

1. add backend runtime abstraction
2. migrate current Codex path behind it with no behavior change
3. introduce backend-aware internal thread identity
4. define backend-neutral store input/update entrypoints
5. add OpenCode runtime warmup + event ingestion
6. add OpenCode direct operation implementations
7. add minimal UniFFI connect/config surface
8. add store and integration tests

#### Validation Targets For Phase 5

Primary:

- `cargo test -p codex-mobile-client`
- `cargo test -p opencode-bridge`

Focused:

- store/reducer tests proving mapped OpenCode inputs produce expected snapshots
- backend runtime tests proving Codex and OpenCode can coexist behind the same internal abstraction
- reconnect/warmup tests for OpenCode directory-scoped sessions

Manual:

- start OpenCode with `litter-opencode-start`
- connect through the mobile Rust facade, not the bridge directly
- verify thread list, read/resume behavior, prompt streaming, interrupt, and approvals through `AppStore` snapshots and `AppClient`

#### Deliverable At End Of Phase 5

At the end of Phase 5, `codex-mobile-client` should be able to host an OpenCode backend end to end behind the existing mobile Rust facade, with backend-neutral store updates and minimal UniFFI changes, ready for the platform connection/config wiring and follow-up validation.

### Phase 6: Tests And Validation

1. Unit-test all OpenCode deserialization and mapping functions with fixtures.
2. Unit-test backend capability behavior for unsupported operations.
3. Unit-test directory-context injection for session create/list/message/prompt/abort/fork/permission/file calls.
4. Add store/reducer tests proving OpenCode events update the same snapshots the UI already observes.
5. Add a fake HTTP/SSE server test for connect, list sessions by directory, send prompt async, stream parts, permission response, and reconnect.
6. Add an ignored/manual integration test against a real `litter-opencode-start` server instance with two directories.
7. Run `cargo test` for `opencode-bridge` and `codex-mobile-client`.

#### Mobile Validation Follow-Up

After the shared Rust bridge is in place, the native validation slice should cover both iOS and Android in the same pass:

1. Extend saved server persistence with backend-aware OpenCode fields:
   - backend kind
   - OpenCode base URL
   - optional basic auth username/password
   - one or more remembered directory scopes
2. Add a manual OpenCode connection form separate from the existing Codex WebSocket/manual server entry.
3. Route the native connect action through `connect_opencode_server(...)` and only remember the server after a successful connect.
4. Verify the minimum end-to-end app workflow:
   - connect
   - thread list
   - read/resume thread
   - start thread in selected directory
   - async prompt streaming
   - interrupt
   - approval response
   - model refresh
5. Verify reconnect and persistence:
   - app relaunch reconnects saved OpenCode servers
   - saved credentials and directory scopes round-trip through native persistence plus Rust reconnect records
   - disconnected/reconnected state remains coherent in UI
6. Update native QA/docs with manual validation steps that explicitly use `litter-opencode-start` and `litter-opencode-creds`.

#### Manual Mobile Validation

Use this sequence for both iOS and Android once the native OpenCode connect form is wired:

1. Start the helper-managed local server with `litter-opencode-start`.
2. Confirm listener state with `litter-opencode-status`.
3. Read the helper-managed basic auth credentials with `litter-opencode-creds`.
4. In the mobile app, choose the OpenCode manual connection path and enter:
   - base URL `http://127.0.0.1:4187`
   - username/password from `litter-opencode-creds`
   - target directory to use as the initial session scope
5. After connect, verify thread list hydration, read/resume, new thread creation in the selected directory, async streaming, interrupt, approval response, and model refresh.
6. Relaunch the app and verify the saved OpenCode record reconnects automatically with the same credentials and directory scope.

## Acceptance Criteria

- Rust can connect to a running OpenCode server with optional basic auth.
- Rust can list OpenCode sessions as Litter threads for a specific directory.
- Rust can preserve OpenCode `Session.directory` in thread identity and snapshots.
- Rust can create OpenCode sessions in the requested Litter cwd using OpenCode directory query/header context.
- Rust can read a session's message history using the session directory context.
- Rust can send a prompt asynchronously using the session directory context and update the store from SSE events.
- Rust can stream text, reasoning, and basic tool state updates into existing conversation projections.
- Rust can abort a running OpenCode session.
- Rust can surface and answer OpenCode permission requests through the existing approval flow.
- Rust can expose connected-provider default models without dumping every OpenCode model into the current picker.
- Swift and Kotlin do not parse OpenCode JSON or SSE payloads.
- The backend abstraction can host a future Pi JSONL/subprocess adapter without changing the public UniFFI surface.

## Open Questions

- Should OpenCode use one `/global/event` stream for all directories, or one `/event?directory=...` stream per active directory in the first implementation?
- How should Litter discover and persist the set of known OpenCode directory scopes for a server?
- Should mobile expose OpenCode server basic auth credentials in the existing server config storage, or should that wait for the multi-provider UI pass?
- Which OpenCode delete/share/summarize/revert actions should map to existing mobile actions, and which should stay hidden until there is matching product UX?
- Should OpenCode agents map to Litter collaboration modes, or remain backend-specific metadata until the UI supports provider-specific agents?
- Should the bridge flatten `provider/model` into the current model string field, or should `codex-mobile-client` add a provider-aware Rust model type before OpenCode ships?
- How much raw OpenCode tool metadata should be preserved for future rendering without exposing unstable provider-specific JSON to the UI?
- Should future Pi support use the same manual server list UI with a backend kind selector, or should local/SSH Pi processes be discovered and launched from a separate flow?

## Recommended First Slice

Build the first slice around an already configured local OpenCode server:

1. Start the local server with `litter-opencode-start`, then verify credentials with `litter-opencode-creds`, then manual connect to `http://127.0.0.1:4187` using those helper-managed basic auth credentials.
2. User selects or enters a directory scope for that server.
3. Health plus `/event?directory=<cwd>` SSE connection.
4. Session list and message hydration for that directory.
5. Create session in selected cwd via `POST /session?directory=<cwd>`.
6. Prompt async with text/reasoning/tool streaming.
7. Abort and permission response.
8. Connected-provider default model list.

This is enough to prove the bridge shape while leaving multi-provider selection, OpenCode login UX, huge model lists, cross-directory/global session browsing, future Pi support, and advanced OpenCode-specific actions for separate product decisions.
