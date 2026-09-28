-- Run with Windows Pragtical: pragtical.com run -n scripts/test-windows.lua
local ffi = require "ffi"
assert(ffi.os == "Windows", "Use the Windows build of Pragtical")
require("plugins.ghostty.config").shell = os.getenv("COMSPEC") or "cmd.exe"
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]scripts[/\\]") or "."
local test = require "core.test"
assert(test.run(root .. "/tests", {

  on_result = function(item)
    test.report_item(item)
  end,

  on_complete = function(results, err)
    assert(results, err)
    test.report(
      results,
      { show_items = false, quit_on_finish = true, force_quit = true }
    )
  end,
}))
