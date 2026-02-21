#pragma once
#include <stdint.h>

/// Start the codex app-server on a random loopback port.
/// On success returns 0 and writes the port to *out_port.
/// On failure returns a negative error code.
int codex_start_server(uint16_t *out_port);

/// Stop the codex app-server (currently a no-op).
void codex_stop_server(void);
