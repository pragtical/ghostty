-- Observe OSC messages that the VT API does not expose as terminal effects.
local Osc = {}
Osc.__index = Osc

local alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local digits = {}
for i = 1, #alphabet do
  digits[alphabet:sub(i, i)] = i - 1
end

---@param text string Base64-encoded clipboard payload.
---@return string? decoded Nil when the payload is malformed.
local function decode(text)
  text = text:gsub("%s", "")
  if text:find("[^%w+/=]") or #text % 4 ~= 0 then
    return
  end
  if text:find("=.+[^=]") or text:find("===") then
    return
  end
  local result = {}
  for i = 1, #text, 4 do
    local a, b = digits[text:sub(i, i)], digits[text:sub(i + 1, i + 1)]
    local c, d = digits[text:sub(i + 2, i + 2)], digits[text:sub(i + 3, i + 3)]
    if not a or not b then
      return
    end
    if not c and text:sub(i + 2, i + 3) ~= "==" then
      return
    end
    if not d and text:sub(i + 3, i + 3) ~= "=" then
      return
    end
    local value = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
    result[#result + 1] = string.char(math.floor(value / 65536))
    if c then
      result[#result + 1] = string.char(math.floor(value / 256) % 256)
    end
    if d then
      result[#result + 1] = string.char(value % 256)
    end
  end
  return table.concat(result)
end

---Create a bounded observer for OSC effects absent from the VT event API.
---@param limit integer Maximum bytes retained for one OSC message.
---@param emit fun(event: table)
---@return table
function Osc.new(limit, emit)
  return setmetatable(
    { limit = limit, emit = emit, state = "ground", parts = {}, length = 0 },
    Osc
  )
end

function Osc:finish()
  if self.length <= self.limit then
    local command, payload = table.concat(self.parts):match("^(%d+);(.*)$")
    if
      command == "7"
      and payload:match("^file://[^/]*(/.*)$")
      and not payload:find("%z")
    then
      self.emit { kind = "cwd-changed", cwd = payload }
    elseif command == "52" then
      local clipboard, encoded = payload:match("^(.-);(.*)$")
      local text = encoded and decode(encoded)
      if text then
        self.emit {
          kind = "clipboard-write-request",
          clipboard = clipboard,
          text = text,
          bytes = #text,
        }
      end
    elseif command == "9" then
      self.emit { kind = "notification", body = payload }
    elseif command == "777" then
      local title, body = payload:match("^notify;([^;]*);(.*)$")
      if title then
        self.emit { kind = "notification", title = title, body = body }
      end
    end
  end
  self.parts, self.length, self.state = {}, 0, "ground"
end

---Consume an output chunk, preserving parser state across chunk boundaries.
---@param data string
function Osc:feed(data)
  local i = 1
  while i <= #data do
    local state = self.state
    if state == "ground" then
      local pos = data:find("\27", i, true)
      if not pos then
        return
      end
      i, self.state = pos + 1, "escape"
    elseif state == "escape" then
      local c = data:sub(i, i)
      self.state = c == "]" and "osc"
        or (
          (c == "P" or c == "_" or c == "^" or c == "X") and "skip"
          or (c == "\27" and "escape" or "ground")
        )
      i = i + 1
    elseif state == "osc" then
      local pos = data:find("[\7\24\26\27]", i) or (#data + 1)
      self.length = self.length + pos - i
      if self.length <= self.limit then
        self.parts[#self.parts + 1] = data:sub(i, pos - 1)
      else
        self.parts = {}
      end
      local c = data:sub(pos, pos)
      if c == "\7" then
        self:finish()
      elseif c == "\27" then
        self.state = "osc_escape"
      elseif c == "\24" or c == "\26" then
        self.parts, self.length, self.state = {}, 0, "ground"
      end
      i = pos + 1
    elseif state == "osc_escape" then
      if data:sub(i, i) == "\\" then
        self:finish()
        i = i + 1
      else
        self.parts, self.length, self.state = {}, 0, "escape"
      end
    elseif state == "skip" then
      local pos = data:find("[\24\26\27]", i)
      if not pos then
        return
      end
      self.state = data:sub(pos, pos) == "\27" and "skip_escape" or "ground"
      i = pos + 1
    else
      self.state = data:sub(i, i) == "\\" and "ground" or "skip"
      i = i + 1
    end
  end
end

return Osc
