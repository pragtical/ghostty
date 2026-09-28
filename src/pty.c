/* POSIX PTY transport. No dependency on Lua or Ghostty.
 * All allocation happens before fork; the child never enters the Lua VM. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

extern char **environ;

typedef struct PgtPty {
  int fd;
  pid_t pid;
  int status;
  int exited;
  int terminating;
  double closed_at;
  struct PgtPty *next;
} PgtPty;

static PgtPty *pending;

static double monotime(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)now.tv_sec + now.tv_nsec / 1000000000.0;
}

int pgt_pty_abi(void) {
  return 1;
}

static int same_key(const char *a, const char *b) {
  size_t n = strcspn(a, "=");
  return strcspn(b, "=") == n && strncmp(a, b, n) == 0;
}

static char **make_env(const char *const *overrides) {
  size_t n = 0, m = 0;
  while (environ[n])
    n++;
  if (overrides)
    while (overrides[m])
      m++;
  char **env = calloc(n + m + 1, sizeof(char *));
  if (!env)
    return NULL;
  size_t out = 0;
  for (size_t i = 0; i < n; i++) {
    size_t j = 0;
    while (j < m && !same_key(environ[i], overrides[j]))
      j++;
    if (j == m)
      env[out++] = environ[i];
  }
  for (size_t j = 0; j < m; j++)
    env[out++] = (char *)overrides[j];
  return env;
}

static char *find_program(const char *name, char **env, const char *cwd) {
  if (strchr(name, '/'))
    return strdup(name);
  const char *path = "/usr/local/bin:/usr/bin:/bin";
  for (char **p = env; *p; p++)
    if (!strncmp(*p, "PATH=", 5))
      path = *p + 5;
  const char *start = path;
  do {
    const char *end = strchr(start, ':');
    size_t len = end ? (size_t)(end - start) : strlen(start);
    char *candidate = NULL;
    if (len && *start == '/') {
      if (asprintf(&candidate, "%.*s/%s", (int)len, start, name) < 0)
        return NULL;
    } else {
      if (asprintf(&candidate, "%s/%.*s/%s", cwd ? cwd : ".",
                   (int)(len ? len : 1), len ? start : ".", name) < 0)
        return NULL;
    }
    if (access(candidate, X_OK) == 0) {
      char *absolute = realpath(candidate, NULL);
      free(candidate);
      return absolute;
    }
    free(candidate);
    start = end ? end + 1 : NULL;
  } while (start);
  errno = ENOENT;
  return NULL;
}

PgtPty *pgt_pty_new(const char *const *argv, const char *const *overrides,
                    const char *cwd, unsigned short cols, unsigned short rows,
                    char *error, size_t error_len) {
  PgtPty *pty = NULL;
  char **env = NULL;
  char *program = NULL;
  int report[2] = {-1, -1};
  if (!argv || !argv[0] || !cols || !rows) {
    errno = EINVAL;
    goto fail;
  }
  pty = calloc(1, sizeof(*pty));
  if (!pty)
    goto fail;
  pty->fd = -1;
  env = make_env(overrides);
  if (!env)
    goto fail;
  program = find_program(argv[0], env, cwd);
  if (!program || pipe(report) < 0)
    goto fail;
  fcntl(report[0], F_SETFD, FD_CLOEXEC);
  fcntl(report[1], F_SETFD, FD_CLOEXEC);
  struct winsize ws = {.ws_col = cols, .ws_row = rows};
  struct sigaction default_action = {.sa_handler = SIG_DFL};
  sigemptyset(&default_action.sa_mask);
  sigset_t empty;
  sigemptyset(&empty);
  long max_fd = sysconf(_SC_OPEN_MAX);
  if (max_fd < 0)
    max_fd = 65536;
  pid_t pid = forkpty(&pty->fd, NULL, NULL, &ws);
  if (pid < 0)
    goto fail;
  if (pid == 0) {
    /* Keep only stdio and the close-on-exec error pipe. */
    int out = report[1];
    if (out != 3) {
      dup2(out, 3);
      out = 3;
    }
    fcntl(out, F_SETFD, FD_CLOEXEC);
#if defined(__linux__)
    if (close_range(4, ~0U, 0) < 0)
      for (int fd = 4; fd < max_fd; fd++)
        close(fd);
#elif defined(__APPLE__)
    for (int fd = 4; fd < max_fd; fd++)
      close(fd);
#endif
    for (int sig = 1; sig < NSIG; sig++)
      sigaction(sig, &default_action, NULL);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    if (!cwd || chdir(cwd) == 0)
      execve(program, (char *const *)argv, env);
    int code = errno;
    (void)!write(out, &code, sizeof(code));
    _exit(127);
  }
  pty->pid = pid;
  close(report[1]);
  report[1] = -1;
  int child_error = 0;
  ssize_t count;
  do {
    count = read(report[0], &child_error, sizeof(child_error));
  } while (count < 0 && errno == EINTR);
  close(report[0]);
  report[0] = -1;
  if (count != 0) {
    if (count < 0)
      kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
    errno = child_error ? child_error : EIO;
    goto fail;
  }
  fcntl(pty->fd, F_SETFD, FD_CLOEXEC);
  int flags = fcntl(pty->fd, F_GETFL);
  if (flags < 0 || fcntl(pty->fd, F_SETFL, flags | O_NONBLOCK) < 0) {
    int saved = errno;
    kill(-pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
    errno = saved;
    goto fail;
  }
  free(program);
  free(env);
  return pty;
fail: {
  int saved = errno;
  if (error && error_len)
    snprintf(error, error_len, "%s", strerror(saved));
  if (report[0] >= 0)
    close(report[0]);
  if (report[1] >= 0)
    close(report[1]);
  if (pty && pty->fd >= 0)
    close(pty->fd);
  free(pty);
  free(program);
  free(env);
  return NULL;
}
}

/* -2 = would block, -1 = error, 0 = EOF. */
long pgt_pty_read(PgtPty *pty, void *buffer, size_t length) {
  ssize_t n;
  do {
    n = read(pty->fd, buffer, length);
  } while (n < 0 && errno == EINTR);
  if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return -2;
  if (n < 0 && errno == EIO)
    return 0;
  return (long)n;
}

long pgt_pty_write(PgtPty *pty, const void *buffer, size_t length) {
  ssize_t n;
  do {
    n = write(pty->fd, buffer, length);
  } while (n < 0 && errno == EINTR);
  if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return -2;
  return (long)n;
}

int pgt_pty_resize(PgtPty *pty, unsigned short cols, unsigned short rows,
                   unsigned short width, unsigned short height) {
  struct winsize ws = {
      .ws_col = cols, .ws_row = rows, .ws_xpixel = width, .ws_ypixel = height};
  return ioctl(pty->fd, TIOCSWINSZ, &ws);
}

int pgt_pty_poll(PgtPty *pty, int *code, int *signal_out) {
  if (!pty->exited) {
    pid_t result;
    do {
      result = waitpid(pty->pid, &pty->status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (result == pty->pid)
      pty->exited = 1;
    else if (result < 0)
      return -1;
  }
  if (!pty->exited)
    return 0;
  *code = WIFEXITED(pty->status) ? WEXITSTATUS(pty->status) : 0;
  *signal_out = WIFSIGNALED(pty->status) ? WTERMSIG(pty->status) : 0;
  return 1;
}

int pgt_pty_pid(PgtPty *pty) {
  return (int)pty->pid;
}

void pgt_pty_close(PgtPty *pty) {
  if (!pty)
    return;
  close(pty->fd);
  if (pty->exited) {
    free(pty);
    return;
  }
  kill(-pty->pid, SIGHUP);
  pty->closed_at = monotime();
  pty->next = pending;
  pending = pty;
}

/* Called on the editor thread, including after the last terminal is closed. */
void pgt_pty_reap(void) {
  PgtPty **link = &pending;
  double now = monotime();
  while (*link) {
    PgtPty *pty = *link;
    pid_t result = waitpid(pty->pid, NULL, WNOHANG);
    if (result == pty->pid || (result < 0 && errno == ECHILD)) {
      *link = pty->next;
      free(pty);
      continue;
    }
    double elapsed = now - pty->closed_at;
    if (elapsed > 0.7)
      kill(-pty->pid, SIGKILL);
    else if (elapsed > 0.2 && !pty->terminating) {
      kill(-pty->pid, SIGTERM);
      pty->terminating = 1;
    }
    link = &pty->next;
  }
}

/* LuaJIT can unload the library when Pragtical restarts. No native worker may
 * still be executing code from it; finish pending children before unloading. */
__attribute__((destructor)) static void shutdown_pending(void) {
  while (pending) {
    PgtPty *pty = pending;
    pending = pty->next;
    kill(-pty->pid, SIGKILL);
    while (waitpid(pty->pid, NULL, 0) < 0 && errno == EINTR) {
    }
    free(pty);
  }
}
