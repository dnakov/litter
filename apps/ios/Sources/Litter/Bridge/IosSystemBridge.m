#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>
#include <TargetConditionals.h>
#include <Foundation/Foundation.h>

// Use ios_system on both device and simulator. The simulator frameworks ship
// the same entry points, and in-process execution is far more reliable than
// trying to spawn host shells from the app sandbox.

extern int ios_system(const char *cmd);
extern FILE *ios_popen(const char *command, const char *type);
extern void ios_setStreams(FILE *in_stream, FILE *out_stream, FILE *err_stream);
extern void ios_waitpid(pid_t pid);
extern pid_t ios_currentPid(void);
extern int ios_getCommandStatus(void);
extern bool joinMainThread;
extern void initializeEnvironment(void);
extern void ios_switchSession(const void *sessionid);
extern void ios_setDirectoryURL(NSURL *workingDirectoryURL);
extern void ios_setContext(const void *context);
extern __thread void *thread_context;
extern NSError *addCommandList(NSString *fileLocation);
extern char **environ;

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

static NSString *codex_ios_decode_wrapped_shell_argument(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length < 2) {
        return nil;
    }

    if ([trimmed hasPrefix:@"'"] && [trimmed hasSuffix:@"'"]) {
        NSString *placeholder = @"__CODEX_SQUOTE__";
        NSString *decoded = [trimmed stringByReplacingOccurrencesOfString:@"'\\''" withString:placeholder];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"'" withString:@""];
        decoded = [decoded stringByReplacingOccurrencesOfString:placeholder withString:@"'"];
        return decoded;
    }

    if ([trimmed hasPrefix:@"\""] && [trimmed hasSuffix:@"\""]) {
        NSString *decoded = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        decoded = [decoded stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        return decoded;
    }

    return nil;
}

static NSString *codex_ios_normalize_shell_command(const char *cmd) {
    NSString *command = cmd ? [NSString stringWithUTF8String:cmd] : @"";
    if (command.length == 0) {
        return command;
    }

    NSArray<NSString *> *prefixes = @[
        @"/bin/bash -lc ",
        @"/bin/bash -c ",
        @"/bin/zsh -lc ",
        @"/bin/zsh -c ",
        @"/bin/sh -lc ",
        @"bash -lc ",
        @"bash -c ",
        @"zsh -lc ",
        @"zsh -c ",
        @"sh -lc ",
    ];
    BOOL changed = YES;
    while (changed) {
        changed = NO;

        for (NSString *prefix in prefixes) {
            if ([command hasPrefix:prefix]) {
                NSString *body = [command substringFromIndex:prefix.length];
                NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
                if (decoded.length > 0 && ([decoded hasPrefix:@"sh -c "] || [decoded isEqualToString:@"sh"])) {
                    command = decoded;
                } else {
                    command = [@"sh -c " stringByAppendingString:body];
                }
                changed = YES;
                break;
            }
        }
        if (changed) {
            continue;
        }

        if ([command hasPrefix:@"sh -c "]) {
            NSString *body = [command substringFromIndex:6];
            NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
            if (decoded.length > 0 && ([decoded hasPrefix:@"sh -c "] || [decoded isEqualToString:@"sh"])) {
                command = decoded;
                changed = YES;
                continue;
            }
        }

        if ([command isEqualToString:@"/bin/bash"]
            || [command isEqualToString:@"/bin/zsh"]
            || [command isEqualToString:@"/bin/sh"]
            || [command isEqualToString:@"bash"]
            || [command isEqualToString:@"zsh"]) {
            command = @"sh";
            changed = YES;
        }
    }

    return [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *codex_ios_host_shell_script(NSString *command) {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"sh -c "]) {
        NSString *body = [trimmed substringFromIndex:6];
        NSString *decoded = codex_ios_decode_wrapped_shell_argument(body);
        if (decoded.length > 0) {
            return decoded;
        }
    }
    return trimmed;
}

static const char *codex_ios_session_name(void) {
    static __thread char *sessionName = NULL;
    if (sessionName == NULL) {
        char buffer[64];
        snprintf(buffer, sizeof(buffer), "codex_session_%p", (void *)pthread_self());
        sessionName = strdup(buffer);
    }
    return sessionName;
}

static NSString *codex_ios_single_quote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void codex_ios_prepare_session(const char *cwd) {
    const char *sessionName = codex_ios_session_name();
    ios_setContext(NULL);
    thread_context = NULL;
    ios_switchSession(sessionName);
    ios_setContext(sessionName);
    thread_context = (void *)sessionName;

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

static int codex_ios_popen_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    NSLog(@"[ios-popen] run cmd='%s' cwd='%s'", cmd, cwd ? cwd : "(null)");

    codex_ios_prepare_session(cwd);

    bool savedJoin = joinMainThread;
    joinMainThread = false;
    FILE *rf = ios_popen(cmd, "r");
    pid_t pid = ios_currentPid();
    joinMainThread = savedJoin;

    if (rf == NULL) {
        NSLog(@"[ios-popen] ios_popen FAILED for cmd='%s'", cmd);
        return -1;
    }

    NSMutableData *data = [NSMutableData data];
    char chunk[4096];
    while (!feof(rf)) {
        size_t count = fread(chunk, 1, sizeof(chunk), rf);
        if (count > 0) {
            [data appendBytes:chunk length:count];
        }
        if (count == 0 && ferror(rf)) {
            NSLog(@"[ios-popen] fread FAILED errno=%d (%s)", errno, strerror(errno));
            break;
        }
    }
    fclose(rf);

    if (pid > 0) {
        ios_waitpid(pid);
    }
    int code = ios_getCommandStatus();

    size_t total = data.length;
    char *buf = NULL;
    if (total > 0) {
        buf = malloc(total + 1);
        if (buf != NULL) {
            memcpy(buf, data.bytes, total);
        } else {
            total = 0;
        }
    }

    NSLog(@"[ios-popen] code=%d output_len=%zu for cmd='%s'", code, total, cmd);

    if (buf && total > 0) {
        buf[total] = '\0';
        *output = buf;
        *output_len = total;
    } else {
        free(buf);
    }

    return code;
}

static int codex_ios_host_spawn_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    NSLog(@"[ios-spawn] run cmd='%s' cwd='%s'", cmd, cwd ? cwd : "(null)");

    int pipefd[2] = {-1, -1};
    if (pipe(pipefd) != 0) {
        NSLog(@"[ios-spawn] pipe FAILED errno=%d (%s)", errno, strerror(errno));
        return -1;
    }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    NSString *scriptString = codex_ios_host_shell_script([NSString stringWithUTF8String:cmd]);
    const char *scriptArg = scriptString.UTF8String;
    const char *cwdArg = (cwd != NULL && cwd[0] != '\0') ? cwd : ".";
    const char *script = "cd \"$1\" && exec /bin/sh -c \"$2\"";
    char *const argv[] = {
        "sh",
        "-c",
        (char *)script,
        "sh",
        (char *)cwdArg,
        (char *)scriptArg,
        NULL
    };

    pid_t pid = 0;
    int spawnErr = posix_spawn(&pid, "/bin/sh", &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (spawnErr != 0) {
        close(pipefd[0]);
        NSLog(@"[ios-spawn] posix_spawn FAILED errno=%d (%s)", spawnErr, strerror(spawnErr));
        return -1;
    }

    NSMutableData *data = [NSMutableData data];
    char chunk[4096];
    for (;;) {
        ssize_t count = read(pipefd[0], chunk, sizeof(chunk));
        if (count > 0) {
            [data appendBytes:chunk length:(NSUInteger)count];
            continue;
        }
        if (count == 0) {
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        NSLog(@"[ios-spawn] read FAILED errno=%d (%s)", errno, strerror(errno));
        break;
    }
    close(pipefd[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            NSLog(@"[ios-spawn] waitpid FAILED errno=%d (%s)", errno, strerror(errno));
            status = -1;
            break;
        }
    }

    int code = -1;
    if (status == -1) {
        code = -1;
    } else if (WIFEXITED(status)) {
        code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        code = 128 + WTERMSIG(status);
    }

    size_t total = data.length;
    char *buf = NULL;
    if (total > 0) {
        buf = malloc(total + 1);
        if (buf != NULL) {
            memcpy(buf, data.bytes, total);
        } else {
            total = 0;
        }
    }

    NSLog(@"[ios-spawn] code=%d output_len=%zu for cmd='%s'", code, total, cmd);

    if (buf && total > 0) {
        buf[total] = '\0';
        *output = buf;
        *output_len = total;
    } else {
        free(buf);
    }

    return code;
}

/// Returns the default working directory for codex sessions (/home/codex inside the sandbox).
NSString *codex_ios_default_cwd(void) {
    NSString *root = codex_sandbox_root();
    if (!root) return nil;
    return [root stringByAppendingPathComponent:@"home/codex"];
}

void codex_ios_system_init(void) {
    initializeEnvironment();
    codex_load_command_list(@"commandDictionary");
    codex_load_command_list(@"extraCommandsDictionary");

    // Set up the sandbox filesystem layout.
    NSString *root = codex_sandbox_root();

    // Configure environment for bundled tools.
    NSString *home = NSHomeDirectory();
    if (home) {
        // SSH/curl config directories.
        setenv("SSH_HOME", [root stringByAppendingPathComponent:@"home/codex"].UTF8String, 0);
        setenv("CURL_HOME", [root stringByAppendingPathComponent:@"home/codex"].UTF8String, 0);
    }
}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    NSString *normalizedCmd = codex_ios_normalize_shell_command(cmd);
    const char *runCmd = normalizedCmd.UTF8String;

#if TARGET_OS_SIMULATOR
    if (cmd != NULL && strcmp(cmd, runCmd) != 0) {
        NSLog(@"[ios-system] normalized cmd from '%s' to '%s'", cmd, runCmd);
    }
    return codex_ios_host_spawn_run(runCmd, cwd, output, output_len);
#endif

    int code = -1;
    pthread_mutex_lock(codex_ios_exec_mutex());
    if (cmd != NULL && strcmp(cmd, runCmd) != 0) {
        NSLog(@"[ios-system] normalized cmd from '%s' to '%s'", cmd, runCmd);
    }

    NSLog(@"[ios-system] run cmd='%s' cwd='%s'", runCmd, cwd ? cwd : "(null)");

    // ios_system uses process-global streams/session state, so all shell work
    // is serialized through a process-wide mutex while staying on the caller thread.
    codex_ios_prepare_session(cwd);

    // Capture output via a temp file. We intentionally NEVER fclose the FILE* —
    // ios_system's background thread cleanup may still reference it.
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codex_exec_%u.tmp", arc4random()]];
    FILE *wf = fopen(tmpPath.UTF8String, "w");
    if (!wf) {
        NSLog(@"[ios-system] tmpfile FAILED for cmd='%s'", runCmd);
        pthread_mutex_unlock(codex_ios_exec_mutex());
        return -1;
    }

    bool savedJoin = joinMainThread;
    joinMainThread = true;
    ios_setStreams(codex_ios_command_stdin(), wf, wf);
    code = ios_system(runCmd);
    joinMainThread = savedJoin;
    fflush(wf);
    ios_setStreams(stdin, stdout, stderr);

    // Read captured output.
    NSData *data = [NSData dataWithContentsOfFile:tmpPath];
    unlink(tmpPath.UTF8String);

    size_t total = 0;
    char *buf = NULL;
    if (data.length > 0) {
        buf = malloc(data.length + 1);
        if (buf) {
            memcpy(buf, data.bytes, data.length);
            total = data.length;
        }
    }

    NSLog(@"[ios-system] code=%d output_len=%zu for cmd='%s'", code, total, runCmd);

    if (buf && total > 0) {
        buf[total] = '\0';
        *output = buf;
        *output_len = total;
    } else {
        free(buf);
    }
    pthread_mutex_unlock(codex_ios_exec_mutex());
    return code;
}
