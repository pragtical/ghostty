#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct PgtPty PgtPty;
PgtPty *pgt_pty_new(const char *const *, const char *const *, const char *,
                    unsigned short, unsigned short, char *, size_t);
long pgt_pty_read(PgtPty *, void *, size_t);
long pgt_pty_write(PgtPty *, const void *, size_t);
int pgt_pty_resize(PgtPty *, unsigned short, unsigned short, unsigned short,
                   unsigned short);
int pgt_pty_poll(PgtPty *, int *, int *);
int pgt_pty_pid(PgtPty *);
void pgt_pty_close(PgtPty *);
void pgt_pty_reap(void);

static char output[2 * 1024 * 1024];
static size_t used;
static ULONGLONG deadline;

static void reset(void) {
  used = 0;
  output[0] = 0;
  deadline = GetTickCount64() + 30000;
}

static void drain(PgtPty *pty) {
  long n;
  do {
    assert(used < sizeof(output) - 1);
    n = pgt_pty_read(pty, output + used, sizeof(output) - used - 1);
    assert(n != -1);
    if (n > 0)
      used += (size_t)n;
  } while (n > 0);
  output[used] = 0;
  if (GetTickCount64() >= deadline) {
    fprintf(stderr, "Timeout. Output: %s\n", output);
    abort();
  }
}

static void until(PgtPty *pty, const char *text) {
  while (!strstr(output, text)) {
    drain(pty);
    Sleep(5);
  }
}

static void exited(PgtPty *pty, int expected) {
  int code, signal;
  for (;;) {
    drain(pty);
    int result = pgt_pty_poll(pty, &code, &signal);
    assert(result >= 0);
    if (result)
      break;
    Sleep(5);
  }
  assert(code == expected && signal == 0);
}

static PgtPty *spawn(const char *const *argv, const char *const *env,
                     const char *cwd) {
  char error[512];
  PgtPty *pty = pgt_pty_new(argv, env, cwd, 93, 31, error, sizeof(error));
  if (!pty) {
    fprintf(stderr, "%s\n", error);
    abort();
  }
  reset();
  return pty;
}

static void send_bytes(PgtPty *pty, const char *data, size_t length) {
  while (length) {
    ULONGLONG start = GetTickCount64();
    long n = pgt_pty_write(pty, data, length);
    assert(GetTickCount64() - start < 1000); /* A full pipe must not block. */
    assert(n != -1);
    if (n > 0) {
      data += n;
      length -= (size_t)n;
    }
    drain(pty);
    if (n == -2)
      Sleep(1);
  }
}

static int child(int argc, char **argv) {
  DWORD mode;
  HANDLE in = GetStdHandle(STD_INPUT_HANDLE),
         out = GetStdHandle(STD_OUTPUT_HANDLE);
  assert(GetConsoleMode(in, &mode));
  assert(SetConsoleMode(in, mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT |
                                     ENABLE_PROCESSED_INPUT)));
  assert(GetConsoleMode(out, &mode));
  assert(SetConsoleMode(out, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING));
  assert(GetConsoleMode(GetStdHandle(STD_ERROR_HANDLE), &mode));
  SetConsoleOutputCP(CP_UTF8);
  if (!strcmp(argv[1], "--probe")) {
    assert(argc == 6 && !strcmp(argv[2], "a b") && !strcmp(argv[3], "a\"b") &&
           !strcmp(argv[4], "space end\\") && !strcmp(argv[5], ""));
    wchar_t value[512], cwd[32768];
    assert(GetEnvironmentVariableW(L"PGT_TEST", value, 512) &&
           !wcscmp(value, L"\x754c\xe9"));
    assert(GetEnvironmentVariableW(L"TERM", value, 512) &&
           !wcscmp(value, L"xterm-256color"));
    assert(GetCurrentDirectoryW(32768, cwd) && wcsstr(cwd, L"ghostty-\x754c"));
    CONSOLE_SCREEN_BUFFER_INFO info;
    assert(GetConsoleScreenBufferInfo(out, &info));
    printf("PROBE_OK:%dx%d\r\n", info.srWindow.Right - info.srWindow.Left + 1,
           info.srWindow.Bottom - info.srWindow.Top + 1);
    fprintf(stderr, "PROBE_STDERR\r\n");
    return 7;
  }
  if (!strcmp(argv[1], "--input")) {
    printf("READY\r\n");
    fflush(stdout);
    size_t total = 0;
    char buffer[4096];
    while (total < 262144) {
      DWORD n;
      assert(ReadFile(in, buffer, sizeof(buffer), &n, NULL) && n);
      for (DWORD i = 0; i < n; i++)
        assert(buffer[i] == 'x');
      total += n;
    }
    CONSOLE_SCREEN_BUFFER_INFO info;
    assert(GetConsoleScreenBufferInfo(out, &info));
    printf("INPUT_OK:%zu:%dx%d\r\n", total,
           info.srWindow.Right - info.srWindow.Left + 1,
           info.srWindow.Bottom - info.srWindow.Top + 1);
    return 0;
  }
  if (!strcmp(argv[1], "--hold")) {
    printf("READY\r\n");
    fflush(stdout);
    Sleep(INFINITE);
  }
  if (!strcmp(argv[1], "--output")) {
    for (int i = 0; i < 10000; i++)
      printf("LINE:%d abcdefghijklmnopqrstuvwxyz\r\n", i);
    printf("FINAL_OUTPUT\r\n");
    return 9;
  }
  return 2;
}

int main(int argc, char **argv) {
  if (argc > 1)
    return child(argc, argv);
  wchar_t executable[32768], temp[32768];
  char exe[65536], directory[65536];
  assert(GetModuleFileNameW(NULL, executable, 32768));
  assert(WideCharToMultiByte(CP_UTF8, 0, executable, -1, exe, sizeof(exe), NULL,
                             NULL));
  DWORD n = GetTempPathW(32000, temp);
  assert(n && n < 32000);
  swprintf(temp + n, 32768 - n, L"ghostty-\x754c-%lu-%llu",
           GetCurrentProcessId(), GetTickCount64());
  assert(CreateDirectoryW(temp, NULL));
  assert(WideCharToMultiByte(CP_UTF8, 0, temp, -1, directory, sizeof(directory),
                             NULL, NULL));
  SetEnvironmentVariableW(L"pgt_test", L"old");
  const char *env[] = {"PGT_TEST=\xe7\x95\x8c\xc3\xa9", "TERM=xterm-256color",
                       NULL};
  const char *probe[] = {exe,           "--probe", "a b", "a\"b",
                         "space end\\", "",        NULL};
  /* Test GUI hosts without standard handles and hosts with redirected pipes.
   * Both must give the child ConPTY handles without changing the host's own. */
  const DWORD streams[] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
                           STD_ERROR_HANDLE};
  HANDLE saved[3], redirected[3], pipe_in, pipe_out;
  assert(CreatePipe(&pipe_in, &pipe_out, NULL, 0));
  redirected[0] = pipe_in;
  redirected[1] = redirected[2] = pipe_out;
  for (int i = 0; i < 3; i++)
    saved[i] = GetStdHandle(streams[i]);
  PgtPty *pty;
  for (int pipes = 0; pipes < 2; pipes++) {
    for (int i = 0; i < 3; i++)
      assert(SetStdHandle(streams[i], pipes ? redirected[i] : NULL));
    pty = spawn(probe, env, directory);
    for (int i = 0; i < 3; i++) {
      assert(GetStdHandle(streams[i]) == (pipes ? redirected[i] : NULL));
      assert(SetStdHandle(streams[i], saved[i]));
    }
    exited(pty, 7);
    assert(strstr(output, "PROBE_OK:93x31"));
    assert(strstr(output, "PROBE_STDERR"));
    pgt_pty_close(pty);
  }
  DWORD leaked;
  assert(PeekNamedPipe(pipe_in, NULL, 0, NULL, &leaked, NULL) && leaked == 0);
  CloseHandle(pipe_in);
  CloseHandle(pipe_out);
  puts("GUI/redirected host handles, TTY, argv, Unicode environment/cwd, size, "
       "exit: passed");

  const char *input[] = {exe, "--input", NULL};
  pty = spawn(input, NULL, NULL);
  until(pty, "READY");
  assert(pgt_pty_resize(pty, 101, 17, 0, 0) == 0);
  char *payload = malloc(262144);
  assert(payload);
  memset(payload, 'x', 262144);
  send_bytes(pty, payload, 262144);
  free(payload);
  exited(pty, 0);
  assert(strstr(output, "INPUT_OK:262144:"));
  if (GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version"))
    puts("SKIP resize effect: Wine's ResizePseudoConsole is a stub");
  else
    assert(strstr(output, "INPUT_OK:262144:101x17"));
  pgt_pty_close(pty);
  puts("Nonblocking large writes and resize request: passed");

  const char *flood[] = {exe, "--output", NULL};
  pty = spawn(flood, NULL, NULL);
  Sleep(100); /* Deliberately let the output pipe fill. */
  exited(pty, 9);
  assert(strstr(output, "FINAL_OUTPUT"));
  pgt_pty_close(pty);
  puts("Output backpressure and final output before exit: passed");

  const char *cmd[] = {
      "cmd.exe", "/d", "/s", "/c", "echo \"quoted value\" & exit /b 3", NULL};
  pty = spawn(cmd, NULL, NULL);
  exited(pty, 3);
  assert(strstr(output, "\"quoted value\""));
  pgt_pty_close(pty);
  puts("cmd.exe command quoting: passed");

  const char *hold[] = {exe, "--hold", NULL};
  for (int i = 0; i < 8; i++) {
    pty = spawn(hold, NULL, NULL);
    until(pty, "READY");
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pgt_pty_pid(pty));
    assert(process);
    ULONGLONG start = GetTickCount64();
    pgt_pty_close(pty);
    assert(GetTickCount64() - start < 1000);
    assert(WaitForSingleObject(process, 5000) == WAIT_OBJECT_0);
    CloseHandle(process);
    pgt_pty_reap();
  }
  puts("Repeated close and child cleanup: passed");
  char error[512];
  const char *missing[] = {"Z:\\ghostty-missing-executable.exe", NULL};
  assert(!pgt_pty_new(missing, NULL, NULL, 80, 24, error, sizeof(error)) &&
         *error);
  assert(!pgt_pty_new(hold, NULL, "Z:\\ghostty-missing-directory", 80, 24,
                      error, sizeof(error)) &&
         *error);
  assert(!pgt_pty_new(hold, NULL, NULL, 0, 24, error, sizeof(error)));
  assert(RemoveDirectoryW(temp));
  puts("Spawn failures: passed");
  return 0;
}
