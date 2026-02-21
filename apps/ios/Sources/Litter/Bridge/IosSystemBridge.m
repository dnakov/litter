#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
// ── Simulator path ──────────────────────────────────────────────────────────
// The iOS Simulator runs as a macOS process, so posix_spawn/popen work fine.
// ios_system is not linked for simulator (its perl xcframeworks lack that
// slice), so we use popen here instead.

void codex_ios_system_init(void) {}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    int old_cwd_fd = open(".", O_RDONLY);
    if (cwd && chdir(cwd) != 0) {
        if (old_cwd_fd >= 0) close(old_cwd_fd);
        return -1;
    }

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    size_t buf_size = 8192;
    char *buf = malloc(buf_size);
    if (!buf) {
        pclose(fp);
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    size_t total = 0;
    size_t n;
    while ((n = fread(buf + total, 1, buf_size - total - 1, fp)) > 0) {
        total += n;
        if (total + 256 >= buf_size) {
            buf_size *= 2;
            char *nb = realloc(buf, buf_size);
            if (!nb) break;
            buf = nb;
        }
    }
    int code = pclose(fp);
    if (old_cwd_fd >= 0) {
        fchdir(old_cwd_fd);
        close(old_cwd_fd);
    }
    buf[total] = '\0';
    *output = buf;
    *output_len = total;
    return WEXITSTATUS(code);
}

#else
// ── Device path ─────────────────────────────────────────────────────────────
// Use ios_system (linked via the ios_system Swift Package) for fork-free exec.

extern int ios_system(const char *cmd);
extern void ios_setStreams(FILE *in_stream, FILE *out_stream, FILE *err_stream);
extern void initializeEnvironment(void);

void codex_ios_system_init(void) {
    initializeEnvironment();
}

int codex_ios_system_run(const char *cmd, const char *cwd, char **output, size_t *output_len) {
    *output = NULL;
    *output_len = 0;

    int old_cwd_fd = open(".", O_RDONLY);
    if (cwd && chdir(cwd) != 0) {
        if (old_cwd_fd >= 0) close(old_cwd_fd);
        return -1;
    }

    int pfd[2];
    if (pipe(pfd) != 0) {
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    FILE *wf = fdopen(pfd[1], "w");
    if (!wf) {
        close(pfd[0]);
        close(pfd[1]);
        if (old_cwd_fd >= 0) {
            fchdir(old_cwd_fd);
            close(old_cwd_fd);
        }
        return -1;
    }

    ios_setStreams(NULL, wf, wf);
    int code = ios_system(cmd);
    fflush(wf);
    fclose(wf);
    ios_setStreams(NULL, stdout, stderr);
    if (old_cwd_fd >= 0) {
        fchdir(old_cwd_fd);
        close(old_cwd_fd);
    }

    size_t buf_size = 8192;
    char *buf = malloc(buf_size);
    if (!buf) { close(pfd[0]); return code; }

    size_t total = 0;
    ssize_t n;
    while ((n = read(pfd[0], buf + total, buf_size - total - 1)) > 0) {
        total += (size_t)n;
        if (total + 256 >= buf_size) {
            buf_size *= 2;
            char *nb = realloc(buf, buf_size);
            if (!nb) break;
            buf = nb;
        }
    }
    close(pfd[0]);
    buf[total] = '\0';
    *output = buf;
    *output_len = total;
    return code;
}

#endif
