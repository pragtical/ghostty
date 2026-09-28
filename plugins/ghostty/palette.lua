-- Build the first sixteen ANSI colors from the active Pragtical theme.
local common = require "core.common"
local M = {}
local syntax_keys = {
  "keyword",
  "keyword2",
  "string",
  "literal",
  "number",
  "operator",
  "function",
}
local style_keys = { "accent", "caret", "good", "warn", "error", "modified" }
-- Hue centers allow the yellow-greens, warm yellows and pinks common in themes.
-- Red, green, yellow, blue, magenta, cyan.
local hues = { 0, 110, 50, 225, 295, 180 }

---@param hue number Hue angle in degrees.
---@return integer ANSI accent family, indexed from one.
local function family(hue)
  if hue < 25 or hue >= 335 then
    return 1
  end
  if hue < 75 then
    return 3
  end
  if hue < 165 then
    return 2
  end
  if hue < 200 then
    return 6
  end
  if hue < 255 then
    return 4
  end
  return 5
end

---@param a integer[]
---@param b integer[]
---@param amount number Interpolation fraction from zero to one.
---@return integer[] rgb
local function mix(a, b, amount)
  local result = {}
  for i = 1, 3 do
    result[i] = common.round(common.lerp(a[i], b[i], amount))
  end
  return result
end

---@param color integer[] RGB channels from zero to 255.
---@return number Relative luminance from zero to one.
local function luminance(color)
  local channels = {}
  for i = 1, 3 do
    local value = color[i] / 255
    channels[i] = value <= 0.04045 and value / 12.92
      or ((value + 0.055) / 1.055) ^ 2.4
  end
  return channels[1] * 0.2126 + channels[2] * 0.7152 + channels[3] * 0.0722
end

---@param a integer[]
---@param b integer[]
---@return number Contrast ratio from one to 21.
local function contrast(a, b)
  local x, y = luminance(a), luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

---@param color integer[]
---@param background integer[]
---@param target integer[] Black or white endpoint for contrast adjustment.
---@param minimum number Minimum contrast ratio.
---@return integer[] rgb
local function readable(color, background, target, minimum)
  if contrast(color, background) >= minimum then
    return mix(color, color, 0)
  end
  local low, high = 0, 1
  for _ = 1, 12 do
    local middle = (low + high) / 2
    if contrast(mix(color, target, middle), background) >= minimum then
      high = middle
    else
      low = middle
    end
  end
  return mix(color, target, high)
end

---@param color integer[] RGB channels from zero to 255.
---@return number hue Angle in degrees.
---@return number saturation Fraction from zero to one.
---@return number lightness Fraction from zero to one.
local function to_hsl(color)
  local r, g, b = color[1] / 255, color[2] / 255, color[3] / 255
  local maximum, minimum = math.max(r, g, b), math.min(r, g, b)
  local delta, lightness = maximum - minimum, (maximum + minimum) / 2
  if delta == 0 then
    return 0, 0, lightness
  end
  local hue
  if maximum == r then
    hue = ((g - b) / delta) % 6
  elseif maximum == g then
    hue = (b - r) / delta + 2
  else
    hue = (r - g) / delta + 4
  end
  return hue * 60, delta / (1 - math.abs(2 * lightness - 1)), lightness
end

---@param hue number Angle in degrees.
---@param saturation number Fraction from zero to one.
---@param lightness number Fraction from zero to one.
---@return integer[] rgb
local function from_hsl(hue, saturation, lightness)
  local c = (1 - math.abs(2 * lightness - 1)) * saturation
  local x, m = c * (1 - math.abs((hue / 60) % 2 - 1)), lightness - c / 2
  local rgb
  if hue < 60 then
    rgb = { c, x, 0 }
  elseif hue < 120 then
    rgb = { x, c, 0 }
  elseif hue < 180 then
    rgb = { 0, c, x }
  elseif hue < 240 then
    rgb = { 0, x, c }
  elseif hue < 300 then
    rgb = { x, 0, c }
  else
    rgb = { c, 0, x }
  end
  for i = 1, 3 do
    rgb[i] = common.round((rgb[i] + m) * 255)
  end
  return rgb
end

---@param theme table
---@param visit fun(color: integer[]?, penalty: integer)
local function sources(theme, visit)
  for _, key in ipairs(syntax_keys) do
    visit((theme.syntax or {})[key], 0)
  end
  -- Prefer syntax accents; UI/status colors can fill missing hues.
  for _, key in ipairs(style_keys) do
    visit(theme[key], 40)
  end
end

---Compare color values, not table identity, to detect theme changes in place.
---@param theme table
---@param foreground integer[]
---@param background integer[]
---@return string
function M.signature(theme, foreground, background)
  local parts = { table.concat(foreground, ","), table.concat(background, ",") }
  sources(theme, function(color)
    parts[#parts + 1] = color and table.concat(color, ",") or "-"
  end)
  return table.concat(parts, ";")
end

---Generate readable theme colors; Lua indices 1..16 map to ANSI indices 0..15.
---@param theme table
---@param foreground integer[]
---@param background integer[]
---@return integer[][] palette
function M.generate(theme, foreground, background)
  local black, white = { 0, 0, 0 }, { 255, 255, 255 }
  local target = contrast(black, background) > contrast(white, background)
      and black
    or white
  local opposite = target == black and white or black
  local candidates, seen = {}, {}
  local saturation, lightness, count = 0, 0, 0
  sources(theme, function(color, penalty)
    if not color then
      return
    end
    local rgb = mix(background, color, (color[4] or 255) / 255)
    local key = table.concat(rgb, ",")
    local h, s, l = to_hsl(rgb)
    local spread = math.max(rgb[1], rgb[2], rgb[3])
      - math.min(rgb[1], rgb[2], rgb[3])
    if s < 0.15 or spread < 24 or l < 0.08 or l > 0.92 or seen[key] then
      return
    end
    seen[key] = true
    candidates[#candidates + 1] =
      { rgb = rgb, hue = h, family = family(h), penalty = penalty }
    -- Prefer syntax accents when estimating colors absent from the theme.
    if penalty == 0 then
      saturation, lightness, count = saturation + s, lightness + l, count + 1
    end
  end)
  saturation = count > 0 and common.clamp(saturation / count, 0.25, 0.8) or 0.5
  lightness = count > 0 and common.clamp(lightness / count, 0.3, 0.7)
    or (target == white and 0.65 or 0.4)

  local palette = {}
  palette[1] = mix(background, opposite, 0.15)
  palette[8] = readable(foreground, background, target, 4.5)
  palette[9] = readable(mix(background, foreground, 0.5), background, target, 3)
  palette[16] = mix(palette[8], target, 0.25)
  for i, hue in ipairs(hues) do
    local best, score
    for _, candidate in ipairs(candidates) do
      local distance = math.abs(candidate.hue - hue)
      distance = math.min(distance, 360 - distance)
      local weight = distance + candidate.penalty
      if candidate.family == i and (not score or weight < score) then
        best, score = candidate, weight
      end
    end
    local color = best and best.rgb or from_hsl(hue, saturation, lightness)
    palette[i + 1] = readable(color, background, target, 4.5)
    -- On light backgrounds, stronger variants get darker to remain readable.
    palette[i + 9] = mix(palette[i + 1], target, 0.18)
  end
  return palette
end

return M
