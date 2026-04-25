#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One-time iSH boot: extracts the bundled `fs` rootfs into
/// `~/Library/Application Support/fs/` (skipped if already
/// present), fixes permissions on `meta.db` so SQLite can write, then calls
/// `ish_init` and caches the resulting kernel instance for subsequent
/// `codex_ish_run` calls. At most one iSH instance per process lifetime.
void codex_ish_init(void);

/// Default working directory for iSH-backed local sessions. Returns `/root`
/// (the standard Alpine home for the root user inside the fakefs).
NSString *_Nullable codex_ish_default_cwd(void);

/// Runs `cmd` through the persistent iSH `/bin/sh`, wrapped with
/// `cd <cwd> && <cmd>` because iSH's shell has no per-call chdir. On return,
/// `*output` points to a malloc'd C buffer (caller frees) of `*output_len`
/// bytes containing merged stdout+stderr, and the return value is the
/// command exit code. Serialized by an internal mutex.
int codex_ish_run(const char *cmd, const char *cwd, char **output, size_t *output_len);

NS_ASSUME_NONNULL_END
