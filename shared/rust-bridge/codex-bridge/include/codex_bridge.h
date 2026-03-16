#pragma once
#include <stdint.h>
#include <stddef.h>

/// Start the codex app-server on a random loopback port.
/// On success returns 0 and writes the port to *out_port.
/// On failure returns a negative error code.
int codex_start_server(uint16_t *out_port);

/// Stop the codex app-server (currently a no-op).
void codex_stop_server(void);

// ---------------------------------------------------------------------------
// In-process channel transport (no WebSocket, no TCP)
// ---------------------------------------------------------------------------

/// Callback invoked from a background thread for every server-to-client message.
/// `json` points to a UTF-8 JSON-RPC string of `json_len` bytes (not null-terminated).
/// The callback must not block.
typedef void (*codex_message_callback)(void *ctx, const char *json, size_t json_len);

/// Open an in-process channel to the codex app-server.
/// Performs the initialize handshake internally before returning.
/// On success returns 0 and writes an opaque handle to *out_handle.
/// The callback will be invoked from a background thread.
int codex_channel_open(codex_message_callback callback, void *ctx, void **out_handle);

/// Send a JSON-RPC message from client to server.
/// `json` is a UTF-8 JSON-RPC string of `json_len` bytes.
/// Returns 0 on success, negative on failure.
int codex_channel_send(void *handle, const char *json, size_t json_len);

/// Close the channel and release resources.
void codex_channel_close(void *handle);
