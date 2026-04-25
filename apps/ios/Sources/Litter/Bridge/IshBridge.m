#import "IshBridge.h"

#import <Foundation/Foundation.h>
#import <netdb.h>
#import <pthread.h>
#import <resolv.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>

#import "ish_embed.h"

static pthread_mutex_t codex_ish_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t codex_ish_exec_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(ish_instance_t *) codex_ish_instance = NULL;

// Single-quote-escape `s` for POSIX sh: x stays 'x', x's becomes 'x'\''s'.
// Caller frees with [NSString release] (ARC handles it).
static NSString *codex_ish_shell_quote(NSString *s) {
    NSString *escaped = [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

// Snapshot the host's DNS resolvers and return an /etc/resolv.conf body.
// Falls back to public resolvers if the host hands back nothing usable
// (no network at launch, no resolv state, etc.).
static NSString *codex_ish_resolv_conf_body(void) {
    NSMutableString *body = [NSMutableString new];
    struct __res_state res;
    if (res_ninit(&res) == 0) {
        if (res.dnsrch[0] != NULL) {
            [body appendString:@"search"];
            for (int i = 0; res.dnsrch[i] != NULL; i++) {
                [body appendFormat:@" %s", res.dnsrch[i]];
            }
            [body appendString:@"\n"];
        }
        union res_sockaddr_union servers[NI_MAXSERV];
        int found = res_getservers(&res, servers, NI_MAXSERV);
        char address[NI_MAXHOST];
        for (int i = 0; i < found; i++) {
            union res_sockaddr_union s = servers[i];
            if (s.sin.sin_len == 0) continue;
            if (getnameinfo((struct sockaddr *)&s.sin, s.sin.sin_len,
                            address, sizeof(address),
                            NULL, 0, NI_NUMERICHOST) == 0) {
                [body appendFormat:@"nameserver %s\n", address];
            }
        }
        res_ndestroy(&res);
    }
    if (![body containsString:@"nameserver "]) {
        // Fallback: public resolvers so apk/curl still work offline-of-host-dns.
        [body appendString:@"nameserver 1.1.1.1\nnameserver 8.8.8.8\n"];
    }
    return body;
}

// Best-effort runtime setup: layer Litter's env policy onto the library's
// minimal defaults, and pre-create the dirs those env vars point at. The
// `export` lines persist for the lifetime of the persistent shell, so all
// subsequent commands inherit them. Going through ish_run (vs. touching the
// fakefs from outside) keeps the SQLite metadata coherent.
static void codex_ish_runtime_setup(void) {
    static const char *const setup =
        // musl treats LANG=C as UTF-8 already; the suffix matches what most
        // tools probe for.
        "export LANG=C.UTF-8 LC_ALL=C.UTF-8 ;"
        "export LOGNAME=root ;"
        "export TMPDIR=/tmp ;"
        // No tty under the exec hook — force pagers to dump-and-exit so
        // things like `git log` / `man` don't block the persistent shell.
        "export PAGER=cat ;"
        "export EDITOR=vi ;"
        "export HOSTNAME=litter ;"
        // Symmetric with the iOS-side CODEX_HOME (which points into the iOS
        // sandbox the codex Rust process actually uses). Tools running inside
        // iSH that look for $CODEX_HOME find a path local to the fakefs.
        "export CODEX_HOME=/root/.codex ;"
        "mkdir -p /root/.codex /tmp ;"
        "chmod 700 /root/.codex ;"
        "chmod 1777 /tmp";

    char *out = NULL;
    size_t out_len = 0;
    int rc = codex_ish_run(setup, NULL, &out, &out_len);
    if (out != NULL) free(out);
    if (rc != 0) {
        NSLog(@"[ish] runtime setup failed rc=%d", rc);
    }
}

// Mount the iOS sandbox `Documents/Apps/` directory inside iSH at
// `/mnt/apps/` via realfs. This lets the model edit saved-app HTML
// directly (`cd /mnt/apps/html && vi foo.html`) while WKWebView and the
// Rust live-sync poller continue to read/write the canonical iOS-sandbox
// file. Without this, the update-app flow would have to stage files in
// the fakefs and copy in/out around every turn.
static void codex_ish_mount_apps_dir(void) {
    NSURL *docs = [[NSFileManager defaultManager]
        URLForDirectory:NSDocumentDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:NULL];
    if (docs == nil) {
        NSLog(@"[ish] could not resolve Documents/ for /mnt/apps mount");
        return;
    }
    NSString *appsDir = [docs.path stringByAppendingPathComponent:@"Apps"];
    [[NSFileManager defaultManager] createDirectoryAtPath:appsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *quoted = codex_ish_shell_quote(appsDir);
    NSString *cmd = [NSString stringWithFormat:
        @"mkdir -p /mnt/apps && mount -t real %@ /mnt/apps", quoted];

    char *out = NULL;
    size_t out_len = 0;
    int rc = codex_ish_run(cmd.UTF8String, NULL, &out, &out_len);
    if (out != NULL) free(out);
    if (rc != 0) {
        NSLog(@"[ish] mount /mnt/apps failed rc=%d", rc);
    } else {
        NSLog(@"[ish] /mnt/apps mounted from '%@'", appsDir);
    }
}

// Write /etc/resolv.conf inside the running iSH kernel via the persistent
// shell. Going through ish_run keeps the fakefs SQLite metadata coherent
// (vs. dropping a bare file into the data/ tree from outside).
static void codex_ish_write_resolv_conf(void) {
    NSString *body = codex_ish_resolv_conf_body();
    NSString *quoted = codex_ish_shell_quote(body);
    NSString *cmd = [NSString stringWithFormat:@"printf %%s %@ > /etc/resolv.conf", quoted];

    char *out = NULL;
    size_t out_len = 0;
    int rc = codex_ish_run(cmd.UTF8String, NULL, &out, &out_len);
    if (out != NULL) free(out);
    if (rc != 0) {
        NSLog(@"[ish] failed to write /etc/resolv.conf rc=%d", rc);
    } else {
        NSLog(@"[ish] /etc/resolv.conf installed (%lu bytes)", (unsigned long)body.length);
    }
}

static NSString *codex_ish_rootfs_dir(void) {
    // Application Support survives low-disk pressure (unlike Caches), so
    // apk-installed packages and user edits inside the fakefs persist
    // across normal device usage. Still wiped on app uninstall.
    NSURL *root = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:NULL];
    if (root == nil) return nil;
    return [root.path stringByAppendingPathComponent:@"fs"];
}

static BOOL codex_ish_extract_rootfs_if_needed(NSString *destination) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:destination isDirectory:&isDir] && isDir) {
        return YES;
    }

    NSURL *bundled = [[NSBundle mainBundle] URLForResource:@"fs"
                                             withExtension:nil];
    if (bundled == nil) {
        NSLog(@"[ish] bundled fs not found in main bundle");
        return NO;
    }

    NSError *error = nil;
    NSString *parent = [destination stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:parent]) {
        if (![fm createDirectoryAtPath:parent
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&error]) {
            NSLog(@"[ish] failed to create cache parent '%@': %@", parent, error);
            return NO;
        }
    }

    if (![fm copyItemAtPath:bundled.path toPath:destination error:&error]) {
        NSLog(@"[ish] failed to copy fs to '%@': %@", destination, error);
        return NO;
    }
    return YES;
}

void codex_ish_init(void) {
    pthread_mutex_lock(&codex_ish_init_mutex);
    if (atomic_load(&codex_ish_instance) != NULL) {
        pthread_mutex_unlock(&codex_ish_init_mutex);
        return;
    }

    NSString *cacheRoot = codex_ish_rootfs_dir();
    if (cacheRoot.length == 0) {
        NSLog(@"[ish] could not resolve caches directory");
        pthread_mutex_unlock(&codex_ish_init_mutex);
        return;
    }

    if (!codex_ish_extract_rootfs_if_needed(cacheRoot)) {
        pthread_mutex_unlock(&codex_ish_init_mutex);
        return;
    }

    NSString *metaDb = [cacheRoot stringByAppendingPathComponent:@"meta.db"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:metaDb]) {
        if (chmod(metaDb.fileSystemRepresentation, 0644) != 0) {
            NSLog(@"[ish] chmod 0644 on meta.db failed (errno=%d)", errno);
        }
    }

    NSString *dataPath = [cacheRoot stringByAppendingPathComponent:@"data"];
    NSLog(@"[ish] booting kernel with rootfs='%@' workdir='/root'", dataPath);
    ish_instance_t *instance = ish_init(dataPath.fileSystemRepresentation, "/root");
    if (instance == NULL) {
        NSLog(@"[ish] ish_init returned NULL — boot failed");
    } else {
        NSLog(@"[ish] kernel booted");
    }
    atomic_store(&codex_ish_instance, instance);

    pthread_mutex_unlock(&codex_ish_init_mutex);

    // Refresh /etc/resolv.conf from the host's current DNS config on every
    // boot — handles network changes between launches. Done outside the
    // init mutex (codex_ish_run takes its own exec mutex).
    if (instance != NULL) {
        codex_ish_runtime_setup();
        codex_ish_write_resolv_conf();
        codex_ish_mount_apps_dir();
    }
}

NSString *codex_ish_default_cwd(void) {
    return @"/root";
}

int codex_ish_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    ish_instance_t *instance = atomic_load(&codex_ish_instance);
    if (instance == NULL) {
        NSLog(@"[ish] codex_ish_run called before codex_ish_init succeeded");
        return ISH_E_NOT_RUNNING;
    }
    if (cmd == NULL) {
        return ISH_E_ARGS;
    }

    NSString *cmdString = [NSString stringWithUTF8String:cmd];
    NSString *wrapped;
    if (cwd != NULL && cwd[0] != '\0') {
        NSString *cwdQuoted = codex_ish_shell_quote([NSString stringWithUTF8String:cwd]);
        wrapped = [NSString stringWithFormat:@"cd %@ && %@", cwdQuoted, cmdString];
    } else {
        wrapped = cmdString;
    }

    pthread_mutex_lock(&codex_ish_exec_mutex);

    uint8_t *out_bytes = NULL;
    size_t out_len = 0;
    int exit_code = 0;
    int rc = ish_run(instance,
                     wrapped.UTF8String,
                     NULL, 0,
                     &out_bytes, &out_len,
                     &exit_code);

    if (rc != ISH_OK) {
        NSLog(@"[ish] ish_run failed rc=%d", rc);
        if (out_bytes != NULL) {
            ish_free(out_bytes);
        }
        pthread_mutex_unlock(&codex_ish_exec_mutex);
        return rc;
    }

    if (out_bytes != NULL && out_len > 0) {
        char *buffer = (char *)malloc(out_len);
        if (buffer == NULL) {
            ish_free(out_bytes);
            pthread_mutex_unlock(&codex_ish_exec_mutex);
            return ISH_E_NOMEM;
        }
        memcpy(buffer, out_bytes, out_len);
        *output = buffer;
        *output_len = out_len;
    }
    if (out_bytes != NULL) {
        ish_free(out_bytes);
    }

    pthread_mutex_unlock(&codex_ish_exec_mutex);
    return exit_code;
}
