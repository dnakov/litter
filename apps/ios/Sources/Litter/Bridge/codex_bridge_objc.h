#import <Foundation/Foundation.h>
#include "../../../../../shared/rust-bridge/codex-bridge/include/codex_bridge.h"

/// Returns the default working directory for local codex sessions (/home/codex inside sandbox).
/// Must be called after codex_ios_system_init().
NSString * _Nullable codex_ios_default_cwd(void);
