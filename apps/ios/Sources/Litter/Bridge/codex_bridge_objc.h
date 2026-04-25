#import <Foundation/Foundation.h>

/// Initializes the iSH (embedded Alpine kernel) runtime. Extracts the bundled
/// rootfs into Application Support on first launch and boots the kernel. At
/// most one iSH instance per process lifetime — see IshBridge.h.
void codex_ish_init(void);

/// Default working directory for iSH-backed local sessions (`/root` inside
/// the Alpine fakefs).
NSString * _Nullable codex_ish_default_cwd(void);

/// Runs `cmd` through the persistent iSH `/bin/sh`, wrapped with
/// `cd <cwd> && <cmd>`. Output is malloc'd into `*output` (caller frees) and
/// the return value is the command exit code.
int codex_ish_run(const char *cmd, const char *cwd, char **output, size_t *output_len);

/// Installs the Rust-side exec hook that dispatches to `codex_ish_run`. Must
/// be called before any Rust client access; otherwise the auto-install in
/// `ensure_platform_init` claims the hook with the default no-op.
void litter_install_ish_hook(void);
