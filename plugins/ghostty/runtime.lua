local ffi = require "ffi"
local json = require "core.json"
local config = require "plugins.ghostty.config"
require "plugins.ghostty.ffi_defs"

local M = {}
M.directory = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
local cpu = ({ x64 = "x86_64", arm64 = "aarch64", x86 = "i686" })[ffi.arch]
  or ffi.arch
local arch = ARCH
  or (cpu .. "-" .. (ffi.os == "OSX" and "darwin" or ffi.os:lower()))
local ext = ffi.os == "Windows" and ".dll" or ".so"

---Load a shared library and verify its required symbols.
---An explicit override is exclusive; otherwise try bundled and system paths.
---@param name string
---@param override? string
---@param symbols? string[]
---@return ffi.namespace library
---@return string path
function M.load(name, override, symbols)
  local candidates = override and override ~= "" and { override }
    or {
      M.directory .. name .. "." .. arch .. ext,
      M.directory .. name .. ext,
      M.directory .. "lib" .. name .. ext,
      M.directory .. "lib" .. name .. ".dylib",
      name,
      "lib" .. name .. (ffi.os == "OSX" and ".dylib" or ext),
    }
  local errors = {}
  for _, path in ipairs(candidates) do

    local ok, lib = pcall(function()
      local library = ffi.load(path)
      for _, symbol in ipairs(symbols or {}) do
        assert(library[symbol])
      end
      return library
    end)

    if ok then
      return lib, path
    end
    errors[#errors + 1] = path .. ": " .. tostring(lib)
  end
  error(
    "Cannot load "
      .. name
      .. ". See the README for binary installation "
      .. "or Meson build instructions.\n"
      .. table.concat(errors, "\n")
  )
end

M.C, M.path = M.load("ghostty-vt", config.runtime_path, {
  "ghostty_terminal_new",
  "ghostty_terminal_grid_ref",
  "ghostty_render_state_update",
  "ghostty_render_state_row_cells_get_multi",
  "ghostty_key_encoder_encode",
  "ghostty_mouse_encoder_encode",
  "ghostty_paste_encode",
  "ghostty_type_json",
})

---Reject incompatible layouts before passing FFI buffers to Ghostty.
---@param metadata string JSON returned by ghostty_type_json().
---@return integer checked Number of verified struct/union layouts.
function M.verify_abi(metadata)
  local manifest, err = json.decode(metadata)
  assert(
    manifest,
    "Invalid libghostty ABI metadata: " .. (err or "expected an object")
  )
  assert(
    type(manifest) == "table" and manifest.schema == 1,
    "Unsupported libghostty ABI schema"
  )
  assert(type(manifest.types) == "table", "Missing libghostty ABI types")
  local checked = 0
  for name, descriptor in pairs(manifest.types) do
    local known, actual = pcall(ffi.sizeof, name)
    if known then
      assert(
        type(descriptor) == "table"
          and actual == descriptor.size
          and ffi.alignof(name) == descriptor.align,
        "Incompatible libghostty layout: " .. name
      )
      if descriptor.kind == "struct" or descriptor.kind == "union" then
        assert(
          type(descriptor.fields) == "table",
          "Missing libghostty fields: " .. name
        )
        for field, layout in pairs(descriptor.fields) do
          assert(
            type(layout) == "table"
              and layout.offset
              and ffi.offsetof(name, field) == layout.offset,
            "Incompatible libghostty field: " .. name .. "." .. field
          )
        end
        checked = checked + 1
      end
    end
  end
  assert(
    checked >= 10,
    "Cannot verify libghostty ABI; use the pinned runtime "
      .. "from this project's Meson build"
  )
  return checked
end

M.verify_abi(ffi.string(M.C.ghostty_type_json()))

function M.check(result, operation)
  if result ~= 0 then
    error(
      (operation or "libghostty") .. " failed (" .. tonumber(result) .. ")",
      2
    )
  end
end

---Allocate a versioned API struct and initialize its size field.
---@param name string
---@return ffi.cdata
function M.sized(name)
  local value = ffi.new(name)
  value.size = ffi.sizeof(name)
  return value
end

return M
