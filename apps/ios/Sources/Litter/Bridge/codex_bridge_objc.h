#import <Foundation/Foundation.h>

/// Initializes the ios_system environment and sandbox filesystem layout.
void codex_ios_system_init(void);

/// Returns the default working directory for local codex sessions (/home/codex inside sandbox).
/// Must be called after codex_ios_system_init().
NSString * _Nullable codex_ios_default_cwd(void);
