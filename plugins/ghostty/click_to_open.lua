local core = require "core"
local common = require "core.common"
local system = require "system"

local click = {}

local trailing = { ["."] = true, [","] = true, [";"] = true, [":"] = true }
local closing = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

---@param url string
---@return boolean opened
local function open_url(url)
  if type(system.open_url) == "function" then
    system.open_url(url)
    return true
  end
  if PLATFORM == "Windows" then
    local ffi = require "ffi"
    ffi.cdef [[
      int __stdcall MultiByteToWideChar(unsigned int, unsigned long,
        const char *, int, wchar_t *, int);
      void * __stdcall ShellExecuteW(void *, const wchar_t *, const wchar_t *,
        const wchar_t *, const wchar_t *, int);
    ]]
    local n = ffi.C.MultiByteToWideChar(65001, 8, url, -1, nil, 0)
    if n == 0 then
      return false
    end
    local wide = ffi.new("wchar_t[?]", n)
    ffi.C.MultiByteToWideChar(65001, 8, url, -1, wide, n)
    local shell32 = ffi.load("shell32")
    return tonumber(
      ffi.cast("intptr_t", shell32.ShellExecuteW(nil, nil, wide, nil, nil, 1))
    ) > 32
  end
  local process = require "process"
  local child = process.start(
    { PLATFORM == "Mac OS X" and "open" or "xdg-open", url },
    { detach = true }
  )
  return child ~= nil
end

---@param text string Candidate URL or path with surrounding punctuation.
---@return string
local function trim_target(text)
  while #text > 0 do
    local last = text:sub(-1)
    if trailing[last] then
      text = text:sub(1, -2)
    elseif closing[last] then
      local open = closing[last]
      local opens = select(2, text:gsub("%" .. open, ""))
      local closes = select(2, text:gsub("%" .. last, ""))
      if closes > opens then
        text = text:sub(1, -2)
      else
        break
      end
    else
      break
    end
  end
  return text
end

---Detect a URL or file reference at a one-based byte offset in a rendered row.
---@param text string
---@param col? integer
---@return table? target
function click.detect(text, col)
  if not text or text == "" then
    return nil
  end
  col = col or 1
  local patterns = {
    { "url", "https?://[%w%p]+" },
    { "file_url", "file://[%w%p]+" },
    { "path", "[A-Za-z]:[/\\][%w_./\\~%-]+:%d+:%d+" },
    { "path", "[A-Za-z]:[/\\][%w_./\\~%-]+:%d+" },
    { "path", "[A-Za-z]:[/\\][%w_./\\~%-]+" },
    { "path", "[%w_./~%-]+:%d+:%d+" },
    { "path", "[%w_./~%-]+:%d+" },
    { "path", "/[%w_./%-]+" },
    { "path", "[%w_.%-]+/[%w_./%-]+" },
  }
  for _, entry in ipairs(patterns) do
    local kind, pattern = entry[1], entry[2]
    local start_at = 1
    while true do
      local s, e = text:find(pattern, start_at)
      if not s then
        break
      end
      if col >= s and col <= e then
        local raw = trim_target(text:sub(s, e))
        local path, line, column = raw:match("^(.-):(%d+):(%d+)$")
        if path then
          return {
            kind = kind,
            target = path,
            line = tonumber(line),
            col = tonumber(column),
            raw = raw,
          }
        end
        path, line = raw:match("^(.-):(%d+)$")
        if path and kind == "path" then
          return {
            kind = kind,
            target = path,
            line = tonumber(line),
            raw = raw,
          }
        end
        return { kind = kind, target = raw, raw = raw }
      end
      start_at = e + 1
    end
  end
  return nil
end

---Resolve a file target against terminal cwd, falling back to the project.
---@param target string
---@param cwd? string
---@param project_root? string
---@return string? path
function click.resolve_file(target, cwd, project_root)
  if not target or target == "" then
    return nil
  end
  if target:match("^file://") then
    return click.decode_file_uri(target)
  end
  if target:match("^[A-Za-z]:[/\\]") or target:sub(1, 2) == "\\\\" then
    return target
  end
  if target:match("^[%w+.-]+:") then
    return nil
  end
  if target:sub(1, 2) == "~/" then
    return common.home_expand(target)
  end
  if target:sub(1, 1) == "/" then
    return target
  end
  if cwd and cwd ~= "" then
    return cwd .. "/" .. target
  end
  if project_root and project_root ~= "" then
    return project_root .. "/" .. target
  end
  return nil
end

---Decode file URLs, including Windows drive and UNC paths; reject NUL bytes.
---@param uri string
---@return string? path
function click.decode_file_uri(uri)
  if not uri or not uri:match("^file://") then
    return nil
  end
  local host, path = uri:match("^file://([^/]*)(/.*)$")
  if not path then
    return nil
  end

  path = path:gsub("%%(%x%x)", function(byte)
    return string.char(tonumber(byte, 16))
  end)

  if path:find("%z") then
    return nil
  end
  if PLATFORM == "Windows" then
    if host ~= "" and host:lower() ~= "localhost" then
      return "//" .. host .. path
    end
    path = path:gsub("^/([A-Za-z]:/)", "%1")
  end
  return path
end

---Open a detected URL externally or a file reference in the editor.
---@param detected? table
---@param cwd? string
---@return boolean opened
function click.open(detected, cwd)
  if not detected then
    return false
  end
  if detected.kind == "url" then
    return open_url(detected.target)
  end
  local root = (core.root_project() or {}).path
  local filename = click.resolve_file(detected.target, cwd, root)
  if not filename then
    return false
  end
  core.root_view:open_doc(core.open_doc(filename))
  local doc = core.active_view and core.active_view.doc
  if doc and detected.line then
    local line = math.max(1, detected.line)
    local col = math.max(1, detected.col or 1)
    doc:set_selection(line, col)
  end
  return true
end

return click
