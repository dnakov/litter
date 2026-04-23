#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#include <Foundation/Foundation.h>

// Use ios_system on both device and simulator. The simulator frameworks ship
// the same entry points, and in-process execution is far more reliable than
// trying to spawn host shells from the app sandbox.

extern int ios_system(const char *cmd);
extern void ios_setStreams(FILE *in_stream, FILE *out_stream, FILE *err_stream);
extern bool joinMainThread;
extern void initializeEnvironment(void);
extern void ios_switchSession(const void *sessionid);
extern void ios_setDirectoryURL(NSURL *workingDirectoryURL);
extern void ios_setContext(const void *context);
extern NSArray *commandsAsArray(void);
extern __thread void *thread_context;
extern __thread FILE *thread_stdout;
extern NSError *addCommandList(NSString *fileLocation);

static const size_t CODEX_IOS_OUTPUT_CAPTURE_LIMIT = 1024 * 1024;
static const size_t CODEX_IOS_COMMAND_LENGTH_LIMIT = 32 * 1024;
static const char *kCodexSessionName = "codex_local";

static NSString *codex_find_command_plist(NSString *name) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithCapacity:4];
    NSString *path = [mainBundle pathForResource:name ofType:@"plist"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    path = [mainBundle pathForResource:name ofType:@"plist" inDirectory:@"ios_system"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    path = [mainBundle pathForResource:name ofType:@"plist" inDirectory:@"Resources/ios_system"];
    if (path.length > 0) {
        [candidates addObject:path];
    }
    NSString *resourceRoot = [mainBundle resourcePath];
    if (resourceRoot.length > 0) {
        path = [resourceRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", name]];
        [candidates addObject:path];
    }
    for (NSString *path in candidates) {
        if (path != nil && path.length > 0) {
            return path;
        }
    }
    return nil;
}

static void codex_load_command_list(NSString *name) {
    NSString *path = codex_find_command_plist(name);
    if (path == nil) {
        NSLog(@"[codex-ios] %@.plist not found in app bundle", name);
        return;
    }
    NSError *error = addCommandList(path);
    if (error != nil) {
        NSLog(@"[codex-ios] failed to load %@.plist: %@", name, error.localizedDescription);
    } else {
        NSLog(@"[codex-ios] loaded %@.plist", name);
    }
}

/// Returns the sandbox root (~/Documents), creating a Unix-like directory layout inside it.
static NSString *codex_sandbox_root(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        @"home/codex",
        @"tmp",
        @"var/log",
        @"etc",
    ];
    for (NSString *dir in dirs) {
        NSString *path = [docs stringByAppendingPathComponent:dir];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    return docs;
}

static FILE *codex_ios_command_stdin(void) {
    static FILE *nullInput = NULL;
    if (nullInput == NULL) {
        nullInput = fopen("/dev/null", "r");
    }
    return nullInput != NULL ? nullInput : stdin;
}

static pthread_mutex_t *codex_ios_exec_mutex(void) {
    static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    return &mutex;
}

static NSData *codex_ios_truncation_notice(size_t originalLength, size_t cap) {
    NSString *message = [NSString stringWithFormat:
        @"\n[output truncated on iOS: captured first %zu of %zu bytes]\n",
        cap,
        originalLength
    ];
    return [message dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
}

static BOOL codex_ios_copy_string_output(
    NSString *message,
    char **output,
    size_t *output_len
) {
    if (output == NULL || output_len == NULL) {
        return NO;
    }

    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    char *buf = malloc(data.length + 1);
    if (buf == NULL) {
        return NO;
    }

    if (data.length > 0) {
        memcpy(buf, data.bytes, data.length);
    }
    buf[data.length] = '\0';
    *output = buf;
    *output_len = data.length;
    return YES;
}

static BOOL codex_ios_read_output_file_limited(
    NSString *path,
    size_t cap,
    char **output,
    size_t *output_len,
    size_t *original_len,
    BOOL *truncated
) {
    if (output == NULL || output_len == NULL || original_len == NULL || truncated == NULL) {
        return NO;
    }

    *output = NULL;
    *output_len = 0;
    *original_len = 0;
    *truncated = NO;

    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        return NO;
    }

    size_t fileLen = st.st_size > 0 ? (size_t)st.st_size : 0;
    *original_len = fileLen;
    if (fileLen == 0) {
        return YES;
    }

    NSData *notice = [NSData data];
    size_t prefixCap = cap;
    if (fileLen > cap) {
        *truncated = YES;
        notice = codex_ios_truncation_notice(fileLen, cap);
        size_t noticeLen = notice.length;
        if (noticeLen >= cap) {
            prefixCap = cap / 2;
        } else {
            prefixCap = cap - noticeLen;
        }
    }

    FILE *rf = fopen(path.fileSystemRepresentation, "r");
    if (rf == NULL) {
        return NO;
    }

    size_t bufferLen = MIN(fileLen, prefixCap) + notice.length;
    char *buf = malloc(bufferLen + 1);
    if (buf == NULL) {
        fclose(rf);
        return NO;
    }

    size_t written = 0;
    while (written < prefixCap) {
        size_t remaining = prefixCap - written;
        size_t chunk = remaining > 8192 ? 8192 : remaining;
        size_t count = fread(buf + written, 1, chunk, rf);
        if (count > 0) {
            written += count;
            continue;
        }
        if (feof(rf)) {
            break;
        }
        if (ferror(rf)) {
            NSLog(@"[ios-system] fread FAILED errno=%d (%s)", errno, strerror(errno));
            free(buf);
            fclose(rf);
            return NO;
        }
    }
    fclose(rf);

    if (notice.length > 0) {
        memcpy(buf + written, notice.bytes, notice.length);
        written += notice.length;
    }
    buf[written] = '\0';

    *output = buf;
    *output_len = written;
    return YES;
}

static NSString *codex_ios_command_string(const char *cmd) {
    NSString *command = cmd ? [NSString stringWithUTF8String:cmd] : @"";
    return [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void codex_ios_prepare_session(const char *cwd) {
    ios_setContext(NULL);
    thread_context = NULL;
    ios_switchSession(kCodexSessionName);
    ios_setContext(kCodexSessionName);
    thread_context = (void *)kCodexSessionName;

    if (cwd == NULL || cwd[0] == '\0') {
        return;
    }

    NSString *cwdString = [NSString stringWithUTF8String:cwd];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cwdString]) {
        [fm createDirectoryAtPath:cwdString withIntermediateDirectories:YES attributes:nil error:nil];
    }
    ios_setDirectoryURL([NSURL fileURLWithPath:cwdString isDirectory:YES]);
}

// MARK: - which / command shims
//
// ios_system doesn't ship these as _main symbols. Register them through
// extraCommandsDictionary.plist with framework name "MAIN" so ios_system's
// regular dispatcher can invoke them, which routes stdout/stderr through
// thread_stdout/thread_stderr like any other bundled command.

static FILE *codex_ios_out(void) {
    return thread_stdout ? thread_stdout : stdout;
}

__attribute__((used))
int which_main(int argc, char **argv) {
    if (argc <= 1) {
        return 0;
    }
    NSArray *known = commandsAsArray() ?: @[];
    int allFound = 1;
    for (int i = 1; i < argc; i++) {
        if (argv[i] == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:argv[i]];
        if ([known containsObject:name]) {
            fprintf(codex_ios_out(), "%s\n", argv[i]);
        } else {
            allFound = 0;
        }
    }
    return allFound ? 0 : 1;
}

__attribute__((used))
int command_main(int argc, char **argv) {
    if (argc <= 1) {
        return 0;
    }
    int mode = 0; // 0 = pass-through, 1 = -v, 2 = -V
    int first = 1;
    while (first < argc && argv[first] != NULL && argv[first][0] == '-' && argv[first][1] != '\0') {
        if (strcmp(argv[first], "-v") == 0) {
            mode = 1;
        } else if (strcmp(argv[first], "-V") == 0) {
            mode = 2;
        } else if (strcmp(argv[first], "--") == 0) {
            first++;
            break;
        } else {
            break;
        }
        first++;
    }

    if (mode == 0) {
        // `command foo arg1 ...` — run `foo arg1 ...` directly. ios_system is
        // its own dispatcher, so re-entering it is cheap; we just need to
        // re-quote argv tokens that contain shell metacharacters.
        NSCharacterSet *special = [NSCharacterSet characterSetWithCharactersInString:@" \t\n'\"\\|&;<>()$`!*?[]{}#"];
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:argc - first];
        for (int i = first; i < argc; i++) {
            if (argv[i] == NULL) continue;
            NSString *token = [NSString stringWithUTF8String:argv[i]];
            if (token.length == 0 || [token rangeOfCharacterFromSet:special].location != NSNotFound) {
                NSString *escaped = [token stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
                token = [NSString stringWithFormat:@"'%@'", escaped];
            }
            [parts addObject:token];
        }
        NSString *rebuilt = [parts componentsJoinedByString:@" "];
        return ios_system(rebuilt.UTF8String);
    }

    NSArray *known = commandsAsArray() ?: @[];
    int allFound = 1;
    for (int i = first; i < argc; i++) {
        if (argv[i] == NULL) continue;
        NSString *name = [NSString stringWithUTF8String:argv[i]];
        if ([known containsObject:name]) {
            if (mode == 2) {
                fprintf(codex_ios_out(), "%s is available in ios_system\n", argv[i]);
            } else {
                fprintf(codex_ios_out(), "%s\n", argv[i]);
            }
        } else {
            allFound = 0;
        }
    }
    return allFound ? 0 : 1;
}

// MARK: - exec

static int codex_ios_run_captured(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    codex_ios_prepare_session(cwd);

    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codex_exec_%u.tmp", arc4random()]];
    FILE *wf = fopen(tmpPath.UTF8String, "w");
    if (!wf) {
        NSLog(@"[ios-system] tmpfile FAILED for cmd='%s'", cmd);
        return -1;
    }

    bool savedJoin = joinMainThread;
    joinMainThread = true;
    ios_setStreams(codex_ios_command_stdin(), wf, wf);
    int code = ios_system(cmd);
    joinMainThread = savedJoin;
    fflush(wf);
    // Swap streams back to libc defaults before closing wf so no part of
    // ios_system is still holding onto it.
    ios_setStreams(stdin, stdout, stderr);
    fclose(wf);

    size_t originalLen = 0;
    BOOL truncated = NO;
    BOOL readOK = codex_ios_read_output_file_limited(
        tmpPath,
        CODEX_IOS_OUTPUT_CAPTURE_LIMIT,
        output,
        output_len,
        &originalLen,
        &truncated
    );
    unlink(tmpPath.UTF8String);
    if (!readOK) {
        NSLog(@"[ios-system] failed to read captured output for cmd='%s'", cmd);
    }

    NSLog(
        @"[ios-system] code=%d output_len=%zu original_len=%zu truncated=%d for cmd='%s'",
        code,
        output_len != NULL ? *output_len : 0,
        originalLen,
        truncated,
        cmd
    );
    return code;
}

/// Returns the default working directory for codex sessions (/home/codex inside the sandbox).
NSString *codex_ios_default_cwd(void) {
    NSString *root = codex_sandbox_root();
    if (!root) return nil;
    return [root stringByAppendingPathComponent:@"home/codex"];
}

void codex_ios_system_init(void) {
    // Keep the MAIN-dispatched shims reachable so neither the compiler nor the
    // linker drops them before ios_system's dlsym(RTLD_MAIN_ONLY) can find them.
    volatile void *keep[] = { (void *)&which_main, (void *)&command_main };
    (void)keep;

    initializeEnvironment();
    codex_load_command_list(@"commandDictionary");
    codex_load_command_list(@"extraCommandsDictionary");

    NSString *root = codex_sandbox_root();
    if (root.length > 0) {
        NSString *home = [root stringByAppendingPathComponent:@"home/codex"];
        setenv("HOME", home.UTF8String, 1);
        setenv("SSH_HOME", home.UTF8String, 0);
        setenv("CURL_HOME", home.UTF8String, 0);
        // Note: deliberately NOT calling ios_setMiniRoot — it retargets `~`
        // to the mini-root instead of $HOME, which double-prefixes any path
        // the model writes as `~/…` (observed as `Documents/Documents/...`).
    }

    // Point TMPDIR at the real iOS temp dir so tools that honor $TMPDIR
    // (mktemp, etc.) land in a writable location. The Rust shell preflight
    // reads $TMPDIR and rewrites literal `/tmp/...` argv/script paths to this.
    NSString *tmpdir = NSTemporaryDirectory();
    if (tmpdir.length > 0) {
        setenv("TMPDIR", tmpdir.UTF8String, 1);
    }
}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    NSString *command = codex_ios_command_string(cmd);
    size_t commandLen = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (commandLen > CODEX_IOS_COMMAND_LENGTH_LIMIT) {
        NSString *message = [NSString stringWithFormat:
            @"command rejected on iOS: %zu bytes exceeds limit of %zu bytes\n",
            commandLen,
            CODEX_IOS_COMMAND_LENGTH_LIMIT
        ];
        codex_ios_copy_string_output(message, output, output_len);
        NSLog(
            @"[ios-system] rejected oversized cmd len=%zu limit=%zu cwd='%s'",
            commandLen,
            CODEX_IOS_COMMAND_LENGTH_LIMIT,
            cwd ? cwd : "(null)"
        );
        return 64;
    }

    const char *runCmd = command.UTF8String;

    pthread_mutex_lock(codex_ios_exec_mutex());
    NSLog(@"[ios-system] run cmd='%s' cwd='%s'", runCmd, cwd ? cwd : "(null)");
    int code = codex_ios_run_captured(runCmd, cwd, output, output_len);
    pthread_mutex_unlock(codex_ios_exec_mutex());
    return code;
}
