/* ConPTY transport. The editor owns overlapped pipe I/O; a native waiter closes
 * the pseudoconsole while the editor drains its final output. No Lua callbacks.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define BUFFER_SIZE 65536
typedef HRESULT(WINAPI *CreateConsoleFn)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef HRESULT(WINAPI *ResizeConsoleFn)(HPCON, COORD);
typedef void(WINAPI *CloseConsoleFn)(HPCON);
static CreateConsoleFn create_console;
static ResizeConsoleFn resize_console;
static CloseConsoleFn close_console;
static INIT_ONCE api_once = INIT_ONCE_STATIC_INIT;
static LONG pipe_number;

typedef struct PgtPty {
  HANDLE input, output, process, job, stop;
  HPCON console;
  SRWLOCK console_lock;
  LONG refs;
  OVERLAPPED read_op, write_op;
  int reading, writing, eof, write_error;
  DWORD read_size, read_offset;
  char read_buffer[BUFFER_SIZE], write_buffer[BUFFER_SIZE];
  HMODULE module;
} PgtPty;

static BOOL CALLBACK load_api(PINIT_ONCE once, PVOID param, PVOID *context) {
  (void)once;
  (void)param;
  (void)context;
  HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
  /* memcpy avoids incompatible function-pointer casts with GCC -Wextra. */
  FARPROC fn = GetProcAddress(kernel, "CreatePseudoConsole");
  memcpy(&create_console, &fn, sizeof(fn));
  fn = GetProcAddress(kernel, "ResizePseudoConsole");
  memcpy(&resize_console, &fn, sizeof(fn));
  fn = GetProcAddress(kernel, "ClosePseudoConsole");
  memcpy(&close_console, &fn, sizeof(fn));
  return TRUE;
}

int pgt_pty_abi(void) {
  return 1;
}

static wchar_t *wide(const char *text) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (!n)
    return NULL;
  wchar_t *result = malloc((size_t)n * sizeof(wchar_t));
  if (!result) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result,
                           n)) {
    free(result);
    return NULL;
  }
  return result;
}

static size_t key_length(const wchar_t *entry) {
  /* Preserve Windows' hidden =C:=... current-directory entries. */
  const wchar_t *equal = wcschr(entry + (*entry == L'='), L'=');
  return equal ? (size_t)(equal - entry) : wcslen(entry);
}

static int same_key(const wchar_t *a, const wchar_t *b) {
  size_t n = key_length(a);
  return n == key_length(b) &&
         CompareStringOrdinal(a, (int)n, b, (int)n, TRUE) == CSTR_EQUAL;
}

static int compare_env(const void *a, const void *b) {
  return CompareStringOrdinal(*(const wchar_t *const *)a, -1,
                              *(const wchar_t *const *)b, -1, TRUE) -
         CSTR_EQUAL;
}

static wchar_t *make_env(const char *const *overrides) {
  wchar_t *inherited = GetEnvironmentStringsW();
  if (!inherited)
    return NULL;
  size_t count = 0, extra = 0;
  for (wchar_t *p = inherited; *p; p += wcslen(p) + 1)
    count++;
  if (overrides)
    while (overrides[extra])
      extra++;
  wchar_t **entries = calloc(count + extra + 1, sizeof(*entries));
  wchar_t **owned = calloc(extra + 1, sizeof(*owned));
  wchar_t *result = NULL;
  DWORD error = ERROR_NOT_ENOUGH_MEMORY;
  if (!entries || !owned)
    goto done;
  size_t used = 0;
  for (wchar_t *p = inherited; *p; p += wcslen(p) + 1)
    entries[used++] = p;
  for (size_t i = 0; i < extra; i++) {
    owned[i] = wide(overrides[i]);
    if (!owned[i]) {
      error = GetLastError();
      goto done;
    }
    if (!*owned[i] || *owned[i] == L'=' || !wcschr(owned[i], L'=')) {
      error = ERROR_INVALID_PARAMETER;
      goto done;
    }
    size_t j = 0;
    while (j < used && !same_key(entries[j], owned[i]))
      j++;
    entries[j] = owned[i];
    if (j == used)
      used++;
  }
  qsort(entries, used, sizeof(*entries), compare_env);
  size_t length = 2;
  for (size_t i = 0; i < used; i++)
    length += wcslen(entries[i]) + 1;
  result = calloc(length, sizeof(wchar_t));
  if (result) {
    wchar_t *out = result;
    for (size_t i = 0; i < used; i++) {
      size_t n = wcslen(entries[i]) + 1;
      memcpy(out, entries[i], n * sizeof(wchar_t));
      out += n;
    }
  }
done:
  if (owned)
    for (size_t i = 0; i < extra; i++)
      free(owned[i]);
  free(owned);
  free(entries);
  FreeEnvironmentStringsW(inherited);
  if (!result)
    SetLastError(error);
  return result;
}

static wchar_t *find_program(const wchar_t *name, const wchar_t *env,
                             const wchar_t *cwd) {
  const wchar_t *path = L"";
  for (const wchar_t *p = env; *p; p += wcslen(p) + 1)
    if (key_length(p) == 4 &&
        CompareStringOrdinal(p, 4, L"PATH", 4, TRUE) == CSTR_EQUAL)
      path = p + 5;
  size_t length = wcslen(path) + (cwd ? wcslen(cwd) : 1) + 2;
  wchar_t *search = malloc(length * sizeof(wchar_t));
  if (!search) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  swprintf(search, length, L"%ls;%ls", cwd ? cwd : L".", path);
  /* Resolve explicit relative paths against the requested working directory. */
  wchar_t *relative = NULL;
  if (cwd && (wcschr(name, L'/') || wcschr(name, L'\\')) && name[0] != L'/' &&
      name[0] != L'\\' && name[1] != L':') {
    size_t n = wcslen(cwd) + wcslen(name) + 2;
    relative = malloc(n * sizeof(wchar_t));
    if (!relative) {
      free(search);
      SetLastError(ERROR_NOT_ENOUGH_MEMORY);
      return NULL;
    }
    swprintf(relative, n, L"%ls\\%ls", cwd, name);
    name = relative;
  }
  DWORD n = SearchPathW(search, name, L".exe", 0, NULL, NULL);
  wchar_t *result = n ? malloc((size_t)n * sizeof(wchar_t)) : NULL;
  if (result && !SearchPathW(search, name, L".exe", n, result, NULL)) {
    free(result);
    result = NULL;
  }
  DWORD error = n && !result ? ERROR_NOT_ENOUGH_MEMORY : GetLastError();
  free(search);
  free(relative);
  if (!result)
    SetLastError(error);
  return result;
}

static wchar_t *command_line(const char *const *argv) {
  size_t count = 0, capacity = 1;
  while (argv[count]) {
    capacity += strlen(argv[count]) * 2 + 3;
    count++;
  }
  wchar_t *line = malloc(capacity * sizeof(wchar_t));
  if (!line) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  const char *base = argv[0];
  for (const char *p = base; *p; p++)
    if (*p == '/' || *p == '\\')
      base = p + 1;
  int cmd = !_stricmp(base, "cmd.exe") || !_stricmp(base, "cmd");
  int command_next = 0;
  wchar_t *out = line;
  for (size_t i = 0; i < count; i++) {
    wchar_t *arg = wide(argv[i]);
    if (!arg) {
      free(line);
      return NULL;
    }
    if (i)
      *out++ = L' ';
    if (command_next && i == count - 1) {
      /* cmd /s /c strips the outer quotes; its command is shell syntax,
       * whereas ordinary argv entries follow the Windows CRT quoting rules. */
      *out++ = L'"';
      size_t n = wcslen(arg);
      memcpy(out, arg, n * sizeof(wchar_t));
      out += n;
      *out++ = L'"';
    } else {
      int quote = !*arg || wcspbrk(arg, L" \t\"") != NULL;
      if (quote)
        *out++ = L'"';
      const wchar_t *p = arg;
      while (*p) {
        size_t slashes = 0;
        while (*p == L'\\') {
          slashes++;
          p++;
        }
        size_t copies = quote && (!*p || *p == L'"') ? slashes * 2 : slashes;
        while (copies--)
          *out++ = L'\\';
        if (*p == L'"')
          *out++ = L'\\';
        if (*p)
          *out++ = *p++;
      }
      if (quote)
        *out++ = L'"';
    }
    command_next = cmd && (!_wcsicmp(arg, L"/c") || !_wcsicmp(arg, L"/k"));
    free(arg);
  }
  *out = 0;
  if (out - line >= 32767) {
    free(line);
    SetLastError(ERROR_BAD_LENGTH);
    return NULL;
  }
  return line;
}

/* ConPTY receives synchronous handles; only our end uses overlapped I/O. */
static int pipe_pair(HANDLE *host, HANDLE *console, int input) {
  wchar_t name[128];
  swprintf(name, 128, L"\\\\.\\pipe\\pragtical-ghostty-%lu-%ld",
           GetCurrentProcessId(), InterlockedIncrement(&pipe_number));
  HANDLE server =
      CreateNamedPipeW(name,
                       (input ? PIPE_ACCESS_OUTBOUND : PIPE_ACCESS_INBOUND) |
                           FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                       PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                       1, BUFFER_SIZE, BUFFER_SIZE, 0, NULL);
  if (server == INVALID_HANDLE_VALUE)
    return 0;
  HANDLE client = CreateFileW(name, input ? GENERIC_READ : GENERIC_WRITE, 0,
                              NULL, OPEN_EXISTING, 0, NULL);
  if (client == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    CloseHandle(server);
    SetLastError(e);
    return 0;
  }
  *host = server;
  *console = client;
  return 1;
}

static void close_handle(HANDLE handle) {
  if (handle && handle != INVALID_HANDLE_VALUE)
    CloseHandle(handle);
}

static void release(PgtPty *pty) {
  if (InterlockedDecrement(&pty->refs))
    return;
  close_handle(pty->process);
  close_handle(pty->job);
  close_handle(pty->stop);
  free(pty);
}

static DWORD WINAPI wait_for_exit(void *data) {
  PgtPty *pty = data;
  HMODULE module = pty->module;
  HANDLE waits[] = {pty->stop, pty->process};
  WaitForMultipleObjects(2, waits, FALSE, INFINITE);
  /* The shell has exited or its view was closed. Also stop any descendants. */
  TerminateJobObject(pty->job, 1);
  AcquireSRWLockExclusive(&pty->console_lock);
  HPCON console = pty->console;
  pty->console = NULL;
  ReleaseSRWLockExclusive(&pty->console_lock);
  close_console(console);
  release(pty);
  /* LuaJIT may unload its reference on restart. Keep our code mapped until
   * this thread has completely finished, without waiting inside DllMain. */
  FreeLibraryAndExitThread(module, 0);
}

static void cancel_pipe(HANDLE pipe, OVERLAPPED *op, int pending) {
  if (pending) {
    DWORD ignored;
    CancelIoEx(pipe, op);
    GetOverlappedResult(pipe, op, &ignored, TRUE);
  }
  close_handle(pipe);
  close_handle(op->hEvent);
}

void pgt_pty_close(PgtPty *pty) {
  if (!pty)
    return;
  cancel_pipe(pty->input, &pty->write_op, pty->writing);
  cancel_pipe(pty->output, &pty->read_op, pty->reading);
  SetEvent(pty->stop);
  release(pty);
}

void pgt_pty_reap(void) { /* The native waiter owns process cleanup. */
}

PgtPty *pgt_pty_new(const char *const *argv, const char *const *overrides,
                    const char *cwd, unsigned short cols, unsigned short rows,
                    char *error, size_t error_len) {
  PgtPty *pty = NULL;
  wchar_t *env = NULL, *directory = NULL, *line = NULL, *program = NULL,
          *name = NULL;
  HANDLE console_in = NULL, console_out = NULL;
  STARTUPINFOEXW startup = {0};
  PROCESS_INFORMATION process = {0};
  int attributes_ready = 0;
  DWORD code = ERROR_INVALID_PARAMETER;
  if (!argv || !argv[0] || !*argv[0] || !cols || !rows || cols > SHRT_MAX ||
      rows > SHRT_MAX)
    goto fail;
  InitOnceExecuteOnce(&api_once, load_api, NULL, NULL);
  if (!create_console || !resize_console || !close_console) {
    code = ERROR_CALL_NOT_IMPLEMENTED;
    goto fail;
  }
  pty = calloc(1, sizeof(*pty));
  if (!pty) {
    code = ERROR_NOT_ENOUGH_MEMORY;
    goto fail;
  }
  pty->refs = 1;
  InitializeSRWLock(&pty->console_lock);
  env = make_env(overrides);
  if (!env)
    goto system_error;
  line = command_line(argv);
  if (!line)
    goto system_error;
  name = wide(argv[0]);
  if (!name)
    goto system_error;
  if (cwd)
    directory = wide(cwd);
  if (!env || !line || !name || (cwd && !directory))
    goto system_error;
  if (directory) {
    DWORD attributes = GetFileAttributesW(directory);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      code = ERROR_DIRECTORY;
      goto fail;
    }
  }
  program = find_program(name, env, directory);
  if (!program)
    goto system_error;
  pty->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
  pty->read_op.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  pty->write_op.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  pty->job = CreateJobObjectW(NULL, NULL);
  if (!pty->stop || !pty->read_op.hEvent || !pty->write_op.hEvent || !pty->job)
    goto system_error;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(pty->job, JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits)))
    goto system_error;
  if (!pipe_pair(&pty->input, &console_in, 1) ||
      !pipe_pair(&pty->output, &console_out, 0))
    goto system_error;
  HRESULT hr = create_console((COORD){(SHORT)cols, (SHORT)rows}, console_in,
                              console_out, 0, &pty->console);
  if (FAILED(hr)) {
    code = HRESULT_CODE(hr);
    goto fail;
  }
  startup.StartupInfo.cb = sizeof(startup);
  /* Prevent redirected host handles from being copied into the child even
   * with bInheritHandles=FALSE. Null handles let ConPTY supply its own streams.
   */
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
  startup.lpAttributeList = malloc(bytes);
  if (!startup.lpAttributeList) {
    code = ERROR_NOT_ENOUGH_MEMORY;
    goto fail;
  }
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes))
    goto system_error;
  attributes_ready = 1;
  if (!UpdateProcThreadAttribute(
          startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
          pty->console, sizeof(pty->console), NULL, NULL))
    goto system_error;
  if (!CreateProcessW(program, line, NULL, NULL, FALSE,
                      EXTENDED_STARTUPINFO_PRESENT |
                          CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
                      env, directory, &startup.StartupInfo, &process))
    goto system_error;
  pty->process = process.hProcess;
  if (!AssignProcessToJobObject(pty->job, process.hProcess))
    goto system_error;
  if (ResumeThread(process.hThread) == (DWORD)-1)
    goto system_error;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                          (LPCWSTR)(uintptr_t)wait_for_exit, &pty->module))
    goto system_error;
  pty->refs = 2;
  HANDLE worker = CreateThread(NULL, 0, wait_for_exit, pty, 0, NULL);
  if (!worker) {
    code = GetLastError();
    pty->refs = 1;
    FreeLibrary(pty->module);
    goto fail;
  }
  CloseHandle(worker);
  close_handle(process.hThread);
  close_handle(console_in);
  close_handle(console_out);
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  free(startup.lpAttributeList);
  free(env);
  free(directory);
  free(line);
  free(program);
  free(name);
  return pty;
system_error:
  code = GetLastError();
fail:
  if (error && error_len) {
    wchar_t message[256] = {0};
    char utf8[768] = {0};
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, code, 0, message, 256, NULL);
    WideCharToMultiByte(CP_UTF8, 0, message, -1, utf8, sizeof(utf8), NULL,
                        NULL);
    snprintf(error, error_len, "ConPTY error %lu: %s", (unsigned long)code,
             code == ERROR_CALL_NOT_IMPLEMENTED
                 ? "Windows 10 version 1809 or later is required"
                 : utf8);
  }
  if (pty) {
    if (pty->process) {
      TerminateProcess(pty->process, 1);
      WaitForSingleObject(pty->process, INFINITE);
    }
    close_handle(pty->input);
    close_handle(pty->output);
    close_handle(pty->read_op.hEvent);
    close_handle(pty->write_op.hEvent);
    if (pty->console)
      close_console(pty->console);
    release(pty);
  }
  close_handle(process.hThread);
  close_handle(console_in);
  close_handle(console_out);
  if (attributes_ready)
    DeleteProcThreadAttributeList(startup.lpAttributeList);
  free(startup.lpAttributeList);
  free(env);
  free(directory);
  free(line);
  free(program);
  free(name);
  return NULL;
}

/* -2 = would block, -1 = error, 0 = EOF. Buffers remain C-owned while pending.
 */
long pgt_pty_read(PgtPty *pty, void *buffer, size_t length) {
  if (!length)
    return -2;
  if (pty->read_offset == pty->read_size) {
    if (pty->eof)
      return 0;
    DWORD count = 0;
    BOOL ok;
    if (pty->reading)
      ok = GetOverlappedResult(pty->output, &pty->read_op, &count, FALSE);
    else {
      ResetEvent(pty->read_op.hEvent);
      ok = ReadFile(pty->output, pty->read_buffer, BUFFER_SIZE, &count,
                    &pty->read_op);
    }
    if (!ok) {
      DWORD error = GetLastError();
      if (error == ERROR_IO_PENDING || error == ERROR_IO_INCOMPLETE) {
        pty->reading = 1;
        return -2;
      }
      pty->reading = 0;
      pty->eof = 1;
      return error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED
                 ? 0
                 : -1;
    }
    pty->reading = 0;
    pty->read_offset = 0;
    pty->read_size = count;
    if (!count) {
      pty->eof = 1;
      return 0;
    }
  }
  size_t available = pty->read_size - pty->read_offset;
  if (length > available)
    length = available;
  memcpy(buffer, pty->read_buffer + pty->read_offset, length);
  pty->read_offset += (DWORD)length;
  return (long)length;
}

long pgt_pty_write(PgtPty *pty, const void *buffer, size_t length) {
  if (pty->write_error)
    return -1;
  DWORD count = 0;
  if (pty->writing) {
    if (!GetOverlappedResult(pty->input, &pty->write_op, &count, FALSE)) {
      if (GetLastError() == ERROR_IO_INCOMPLETE)
        return -2;
      pty->writing = 0;
      pty->write_error = 1;
      return -1;
    }
    pty->writing = 0;
  }
  if (!length)
    return 0;
  if (length > BUFFER_SIZE)
    length = BUFFER_SIZE;
  memcpy(pty->write_buffer, buffer, length);
  ResetEvent(pty->write_op.hEvent);
  if (WriteFile(pty->input, pty->write_buffer, (DWORD)length, &count,
                &pty->write_op))
    return (long)count;
  if (GetLastError() == ERROR_IO_PENDING) {
    pty->writing = 1;
    return (long)length;
  }
  pty->write_error = 1;
  return -1;
}

int pgt_pty_resize(PgtPty *pty, unsigned short cols, unsigned short rows,
                   unsigned short width, unsigned short height) {
  (void)width;
  (void)height;
  if (!cols || !rows || cols > SHRT_MAX || rows > SHRT_MAX)
    return -1;
  AcquireSRWLockExclusive(&pty->console_lock);
  HRESULT hr = pty->console ? resize_console(pty->console,
                                             (COORD){(SHORT)cols, (SHORT)rows})
                            : E_HANDLE;
  ReleaseSRWLockExclusive(&pty->console_lock);
  return SUCCEEDED(hr) ? 0 : -1;
}

int pgt_pty_poll(PgtPty *pty, int *code, int *signal_out) {
  /* Process exit can precede ConPTY's final frame. Wait for the output EOF. */
  if (!pty->eof || pty->read_offset != pty->read_size ||
      WaitForSingleObject(pty->process, 0) != WAIT_OBJECT_0)
    return 0;
  DWORD status;
  if (!GetExitCodeProcess(pty->process, &status))
    return -1;
  *code = (int)status;
  *signal_out = 0;
  return 1;
}

int pgt_pty_pid(PgtPty *pty) {
  return (int)GetProcessId(pty->process);
}
