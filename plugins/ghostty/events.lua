local system = require "system"

local events = {}
local handlers = {}

---Subscribe on the editor thread; returns a function to remove this listener.
---@param name string
---@param fn fun(event: table)
---@return function unsubscribe
function events.on(name, fn)
  assert(type(name) == "string", "event name must be a string")
  assert(type(fn) == "function", "event handler must be a function")
  local list = handlers[name]
  if not list then
    list = {}
    handlers[name] = list
  end
  list[#list + 1] = fn
  return function()
    events.off(name, fn)
  end
end

---Remove a listener; safe to call after it has already been removed.
---@param name string
---@param fn function
function events.off(name, fn)
  local list = handlers[name]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if list[i] == fn then
      table.remove(list, i)
    end
  end
end

---Notify a snapshot of listeners, isolating errors with core.try.
---@param name string
---@param payload? table
function events.emit(name, payload)
  payload = payload or {}
  payload.kind = payload.kind or name
  payload.time = payload.time or system.get_time()
  local list = handlers[name]
  if not list then
    return
  end
  local copy = { table.unpack(list) }
  for _, fn in ipairs(copy) do
    require("core").try(fn, payload)
  end
end

return events
