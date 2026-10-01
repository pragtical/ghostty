local common = require "core.common"
local selection = {}

function selection.new()
  return { active = false, anchor = nil, cursor = nil, dragged = false }
end

---@param a? table First endpoint with one-based row and column fields.
---@param b? table Second endpoint with one-based row and column fields.
---@return table? first
---@return table? last
local function normalize(a, b)
  if not a or not b then
    return nil
  end
  if a.row > b.row or (a.row == b.row and a.col > b.col) then
    a, b = b, a
  end
  return a, b
end

---Start a drag, optionally with an inclusive range already selected.
---@param state table
---@param col integer
---@param row integer
---@param end_col? integer
---@param end_row? integer
function selection.start(state, col, row, end_col, end_row)
  state.active = true
  state.anchor = { col = col, row = row }
  state.cursor = { col = end_col or col, row = end_row or row }
  state.dragged = end_col ~= nil
  state.initial = end_col and { state.anchor, state.cursor } or nil
end

function selection.update(state, col, row)
  if not state.active then
    return false
  end
  local cursor = { col = col, row = row }
  if state.initial then
    local first, last = state.initial[1], state.initial[2]
    local left = normalize(first, cursor)
    state.anchor = left == cursor and last or first
    if left == first then
      local _, right = normalize(last, cursor)
      cursor = right
    end
  end
  if
    state.cursor
    and state.cursor.col == cursor.col
    and state.cursor.row == cursor.row
  then
    return false
  end
  state.cursor = cursor
  state.dragged = true
  return true
end

function selection.finish(state)
  state.active = false
  state.initial = nil
  if not state.dragged then
    state.anchor = nil
    state.cursor = nil
  end
end

---Return ordered endpoints with one-based row and column coordinates.
---@param state table
---@return table? first
---@return table? last
function selection.range(state)
  if not state.dragged and not state.active then
    return nil
  end
  return normalize(state.anchor, state.cursor)
end

function selection.has_selection(state)
  return selection.range(state) ~= nil
end

---Return inclusive selected columns for a row, clamped to the visible grid.
---@param state table
---@param row integer
---@param cols integer
---@return integer? start_col
---@return integer? end_col
function selection.row_range(state, row, cols)
  local first, last = selection.range(state)
  if not first or not last or row < first.row or row > last.row then
    return nil
  end
  local start_col = row == first.row and first.col or 1
  local end_col = row == last.row and last.col or cols
  if start_col > end_col then
    start_col, end_col = end_col, start_col
  end
  start_col = common.clamp(start_col, 1, cols)
  end_col = common.clamp(end_col, 1, cols)
  if end_col < 1 or start_col > cols then
    return nil
  end
  return start_col, end_col
end

return selection
