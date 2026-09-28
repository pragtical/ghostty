#define _DEFAULT_SOURCE
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef struct PgtPty PgtPty;
PgtPty *pgt_pty_new(const char *const *, const char *const *, const char *,
                    unsigned short, unsigned short, char *, size_t);
long pgt_pty_read(PgtPty *, void *, size_t);
int pgt_pty_poll(PgtPty *, int *, int *);
void pgt_pty_close(PgtPty *);

int main(void) {
  char error[512], buffer[4096] = {0};
  const char *argv[] = {
      "/bin/sh", "-c",
      "test -t 0 && test -t 1 && test -t 2 && printf '%s:%s:' \"$PGT_TEST\" "
      "\"$TERM\" && pwd && stty size; exit 7",
      NULL};
  const char *env[] = {"PGT_TEST=ffi", "TERM=xterm-256color", NULL};
  PgtPty *pty = pgt_pty_new(argv, env, "/tmp", 93, 31, error, sizeof(error));
  if (!pty) {
    fprintf(stderr, "%s\n", error);
    return 1;
  }
  size_t used = 0;
  int code = -1, signal = -1, done = 0;
  for (int i = 0; i < 500; i++) {
    long count = pgt_pty_read(pty, buffer + used, sizeof(buffer) - used - 1);
    if (count > 0)
      used += (size_t)count;
    if (count <= 0 && pgt_pty_poll(pty, &code, &signal) == 1) {
      done = 1;
      break;
    }
    usleep(10000);
  }
  buffer[used] = 0;
  assert(done && code == 7 && signal == 0);
  assert(strstr(buffer, "ffi:xterm-256color:/tmp") ||
         strstr(buffer, "ffi:xterm-256color:/private/tmp"));
  assert(strstr(buffer, "31 93"));
  pgt_pty_close(pty);
  const char *missing[] = {"/does/not/exist", NULL};
  assert(!pgt_pty_new(missing, NULL, NULL, 80, 24, error, sizeof(error)));
  assert(error[0]);
  assert(!pgt_pty_new(argv, NULL, "/does/not/exist", 80, 24, error,
                      sizeof(error)));
  puts("PTY spawn, TTY, environment, cwd, size, exit, failure cleanup: passed");
  return 0;
}
