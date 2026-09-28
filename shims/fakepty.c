/* fakepty.c  -  make a pipe-backed session believe it has a terminal.
 *
 * For environments where the kernel offers no /dev/ptmx (sealed cages,
 * seccomp profiles without mknod/devpts, some CI sandboxes). This is a
 * USERSPACE pty: it interposes isatty/tcgetattr/tcsetattr/ioctl for the
 * session's own descriptors so readline, curses, nano, less and top get the
 * termios and window size they ask for, and it maps /dev/tty onto the session
 * descriptors so a program that opens it explicitly also gets a terminal.
 *
 * WHY NOT openpty. faketty and fakepty both allocate a kernel pty with
 * openpty(3), which needs /dev/ptmx and a mounted devpts. A cage has neither,
 * so `script`, `openpty` and both of those tools fail with "out of pty
 * devices" (measured on this host). A userspace interposer is the only thing
 * that works where the kernel offers no pty at all.
 *
 * Build: gcc -shared -fPIC -O2 -o fakepty.so fakepty.c
 * Use:   LD_PRELOAD=./fakepty.so nano file      (the faketty wrapper does this)
 *
 * SESSION SCOPING. Reporting every fd 0-2 as a terminal makes a program that
 * reads a PIPE believe it is interactive, so colourising tools write ANSI
 * codes into machine-read output:
 *   LD_PRELOAD=fakepty.so jq -n '{ok:1}'   -> ANSI codes inside the JSON
 * With SANDHOME_FAKEPTY_ID set (the faketty wrapper sets it to the readlink()
 * identity of fds 0-2), only descriptors referring to those SAME objects are
 * treated as a terminal. An fd the program later opens onto a pipe is not one
 * of them, so `jq | cat` inside a faked session still sees a pipe. Without the
 * variable the old behaviour is kept and fds 0-2 are faked, which is what the
 * shell shim has always done.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <fcntl.h>
#include <limits.h>

#define SH_MAXIDS 3

static char sh_ids[SH_MAXIDS][PATH_MAX * 2];
static int  sh_nids = 0;
static int  sh_have_ids = 0;

/* Read the session descriptor identities once, at load. */
static void sh_load_ids(void) {
    const char *e = getenv("SANDHOME_FAKEPTY_ID");
    char buf[4096];
    char *p;
    if (!e || !*e) return;
    snprintf(buf, sizeof buf, "%s", e);
    p = buf;
    while (*p && sh_nids < SH_MAXIDS) {
        char *s;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        s = p;
        while (*p && *p != ' ' && *p != '\t') p++;
        if (*p) *p++ = '\0';
        if (*s) {
            snprintf(sh_ids[sh_nids], sizeof sh_ids[0], "%s", s);
            sh_nids++;
        }
    }
    if (sh_nids) sh_have_ids = 1;
}

__attribute__((constructor)) static void sh_fakepty_init(void) { sh_load_ids(); }

/* The readlink() identity of a descriptor, e.g. "pipe:[123]" or "socket:[9]". */
static int sh_fd_identity(int fd, char *out, size_t n) {
    char p[64];
    ssize_t r;
    snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
    r = readlink(p, out, n - 1);
    if (r < 0) return -1;
    out[r] = '\0';
    return 0;
}

static int sh_id_listed(const char *id) {
    int i;
    for (i = 0; i < sh_nids; i++) {
        if (strcmp(id, sh_ids[i]) == 0) return 1;
    }
    return 0;
}

/* sh_fakefd: is this descriptor part of the faked session? */
static int sh_fakefd(int fd) {
    char id[PATH_MAX * 2];
    if (fd < 0) return 0;
    if (!sh_have_ids) return fd == 0 || fd == 1 || fd == 2;
    /* A descriptor that is not one of the session's is NOT a terminal, which is
     * the whole point of the list: an fd opened onto a pipe stays a pipe. Only
     * a readlink that fails (no /proc) falls back to the old fds 0-2 answer. */
    if (sh_fd_identity(fd, id, sizeof id) != 0) return fd == 0 || fd == 1 || fd == 2;
    return sh_id_listed(id);
}

/* The window size, from SANDHOME_FAKEPTY_SIZE ("COLSxROWS"), then COLUMNS and
 * LINES, then 80x24. A full-screen program lays out to this and does not ask
 * again, so it must be sane before the program starts. */
static void sh_winsize(struct winsize *w) {
    const char *e = getenv("SANDHOME_FAKEPTY_SIZE");
    int cols = 80, rows = 24;
    if (e) {
        int c = 0, r = 0;
        if (sscanf(e, "%dx%d", &c, &r) == 2 && c > 0 && r > 0) { cols = c; rows = r; }
    } else {
        const char *c = getenv("COLUMNS"), *r = getenv("LINES");
        if (c && atoi(c) > 0) cols = atoi(c);
        if (r && atoi(r) > 0) rows = atoi(r);
    }
    w->ws_row = (unsigned short)rows;
    w->ws_col = (unsigned short)cols;
    w->ws_xpixel = 0;
    w->ws_ypixel = 0;
}

/* ONLCR translation is opt-out because it is what a real terminal does when
 * the termios reports OPOST|ONLCR, and a program that writes bare \n relies on
 * it. Set SANDHOME_FAKEPTY_CRLF=0 to pass output through byte for byte. */
static int sh_crlf_on(void) {
    const char *e = getenv("SANDHOME_FAKEPTY_CRLF");
    if (e && (strcmp(e, "0") == 0 || strcmp(e, "no") == 0 || strcmp(e, "off") == 0))
        return 0;
    return 1;
}

int isatty(int fd) {
    static int (*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "isatty");
    if (sh_fakefd(fd)) return 1;
    return real(fd);
}

char *ttyname(int fd) {
    static char *(*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "ttyname");
    if (sh_fakefd(fd)) return "/dev/tty";
    return real(fd);
}

int tcgetattr(int fd, struct termios *t) {
    if (sh_fakefd(fd)) {
        memset(t, 0, sizeof(*t));
        t->c_iflag = ICRNL | IXON | BRKINT;
        t->c_oflag = OPOST | ONLCR;
        t->c_cflag = CS8 | CREAD | CLOCAL;
        t->c_lflag = ICANON | ECHO | ECHOE | ECHOK | ISIG | IEXTEN;
        t->c_cc[VMIN] = 1; t->c_cc[VTIME] = 0;
        return 0;
    }
    {
        int (*r)(int, struct termios *) = dlsym(RTLD_NEXT, "tcgetattr");
        return r(fd, t);
    }
}

int tcsetattr(int fd, int act, const struct termios *t) {
    (void)act; (void)t;
    if (sh_fakefd(fd)) return 0;
    {
        int (*r)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
        return r(fd, act, t);
    }
}

/* tcgetpgrp has no terminal group to report; the process group of this process
 * is what a program comparing it to getpgrp() expects to be equal. */
pid_t tcgetpgrp(int fd) {
    static pid_t (*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "tcgetpgrp");
    if (sh_fakefd(fd)) return getpgrp();
    return real(fd);
}

int tcsetpgrp(int fd, pid_t pgrp) {
    static int (*real)(int, pid_t);
    if (!real) real = dlsym(RTLD_NEXT, "tcsetpgrp");
    if (sh_fakefd(fd)) return 0;
    return real(fd, pgrp);
}

/* Map /dev/tty onto the session descriptors. A program that cannot find a tty
 * on stdin opens /dev/tty explicitly; without this it gets ENXIO and refuses
 * to run. O_RDONLY maps to fd 0 (keys), anything wanting to write maps to
 * fd 1 (screen). A single fd cannot be both the input pipe and the output pipe
 * when the session is two pipes, which is what an ssh channel gives. */
static int sh_is_dev_tty(const char *path) {
    if (!path || strcmp(path, "/dev/tty") != 0) return 0;
    /* Only meaningful when the session descriptors really are being faked; in a
     * scoped session where nothing matches, /dev/tty is left to the kernel and
     * fails with ENXIO, which is the honest answer. */
    return sh_fakefd(0) || sh_fakefd(1);
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (sh_is_dev_tty(path) && (flags & (O_WRONLY | O_RDWR))) return dup(1);
    if (sh_is_dev_tty(path)) return dup(0);
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (sh_is_dev_tty(path) && (flags & (O_WRONLY | O_RDWR))) return dup(1);
    if (sh_is_dev_tty(path)) return dup(0);
    {
        int (*r)(const char *, int, ...) = dlsym(RTLD_NEXT, "open64");
        return r(path, flags, mode);
    }
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (sh_is_dev_tty(path)) {
        if (flags & (O_WRONLY | O_RDWR)) return dup(1);
        return dup(0);
    }
    {
        int (*r)(int, const char *, int, ...) = dlsym(RTLD_NEXT, "openat");
        return r(dirfd, path, flags, mode);
    }
}

FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    int fd;
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    if (sh_is_dev_tty(path)) {
        fd = (mode && (mode[0] == 'w' || mode[0] == 'a' || strchr(mode, '+'))) ? dup(1) : dup(0);
        return fd >= 0 ? fdopen(fd, mode) : NULL;
    }
    return real(path, mode);
}

/* A terminal with OPOST|ONLCR turns \n into \r\n as it leaves. A pipe does not,
 * so a program that writes a bare \n draws a staircase. Translate here, leaving
 * an existing \r\n alone, and still report the ORIGINAL byte count because the
 * caller must not be told about bytes it never wrote. */
ssize_t write(int fd, const void *buf, size_t n) {
    static ssize_t (*real)(int, const void *, size_t);
    const unsigned char *in = buf;
    unsigned char *out;
    size_t i, o = 0;
    ssize_t rc;
    if (!real) real = dlsym(RTLD_NEXT, "write");
    if (!sh_fakefd(fd) || !sh_crlf_on() || n == 0) return real(fd, buf, n);
    out = malloc(n * 2 + 1);
    if (!out) return real(fd, buf, n);
    for (i = 0; i < n; i++) {
        if (in[i] == '\n' && (i == 0 || in[i-1] != '\r')) out[o++] = '\r';
        out[o++] = in[i];
    }
    {
        size_t done = 0;
        while (done < o) {
            rc = real(fd, out + done, o - done);
            if (rc < 0) { free(out); return rc; }
            done += (size_t)rc;
        }
    }
    free(out);
    return (ssize_t)n;
}

int ioctl(int fd, unsigned long req, ...) {
    va_list ap; void *arg;
    va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);
    if (sh_fakefd(fd)) {
        switch (req) {
        case TCGETS: {
            struct termios t;
            tcgetattr(fd, &t);
            if (arg) memcpy(arg, &t, sizeof(t));
            return 0;
        }
        case TCSETS: case TCSETSW: case TCSETSF:
            return 0;
        case TIOCGWINSZ: {
            struct winsize *w = arg;
            if (w) sh_winsize(w);
            return 0;
        }
        case TIOCSWINSZ:
            return 0;
        case TIOCGPGRP: {
            pid_t *p = arg;
            if (p) *p = getpgrp();
            return 0;
        }
        case TIOCSPGRP:
            return 0;
        case FIONREAD: {
            int *p = arg;
            if (p) *p = 0;
            return 0;
        }
        }
    }
    {
        int (*r)(int, unsigned long, ...) = dlsym(RTLD_NEXT, "ioctl");
        return r(fd, req, arg);
    }
}
