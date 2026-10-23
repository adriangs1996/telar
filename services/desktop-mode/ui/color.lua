-- Arithmetic on the theme's #RRGGBB and #AARRGGBB colors.
local Color = {}

local function channels(color)
  local alpha = #color == 9 and tonumber(color:sub(2, 3), 16) or 255
  local rgb = color:sub(-6)

  return alpha,
    tonumber(rgb:sub(1, 2), 16),
    tonumber(rgb:sub(3, 4), 16),
    tonumber(rgb:sub(5, 6), 16)
end

-- `color` laid over an opaque `background` at `opacity`.
function Color.blend(color, background, opacity)
  local _, red, green, blue = channels(color)
  local _, behind_red, behind_green, behind_blue = channels(background)

  local function mix(front, behind)
    return math.floor(front * opacity + behind * (1 - opacity) + 0.5)
  end

  return string.format(
    "#%02x%02x%02x",
    mix(red, behind_red),
    mix(green, behind_green),
    mix(blue, behind_blue)
  )
end

-- `color` with its alpha multiplied by `opacity`.
function Color.fade(color, opacity)
  local alpha = channels(color)

  return string.format("#%02x%s", math.floor(alpha * opacity + 0.5), color:sub(-6))
end

return Color
