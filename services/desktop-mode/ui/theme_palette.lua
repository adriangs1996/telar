-- Builds a theme preset from a Neovim colorscheme's palette: its surface, diagnostic, diff
-- and ANSI roles become the desktop's chrome, agent status and terminal colors. Presets in
-- themes/ call it; it is not a preset itself.
local blend = require("color").blend

return function(palette)
  local colors = {
    ground = palette.bg.editor,
    chrome = palette.bg.window,
    raised = palette.bg.inset,
    hover = palette.ui.cursorline,
    selected = palette.ui.visual,
    border = palette.border.editor,
    border_strong = palette.border.elevated,
    text = palette.fg.base,
    muted = palette.fg.fg2,
    label = palette.fg.fg3,
    accent = palette.accent.primary,
    on_accent = palette.accent.contrast,
    error = palette.diagnostic.error,
  }

  local function status(color, background)
    return {
      color = color,
      text = color,
      background = background or blend(color, colors.chrome, 0.12),
      border = blend(color, colors.chrome, 0.55),
    }
  end

  local function idle()
    return {
      color = colors.label,
      text = colors.muted,
      background = colors.raised,
      border = colors.border,
    }
  end

  local ansi = {}

  for name, color in pairs(palette.ansi) do
    ansi[name:gsub("%u", function(letter)
      return "_" .. letter:lower()
    end)] = color
  end

  return {
    wallpaper = { image = palette.wallpaper or "" },
    colors = colors,
    status = {
      working = status(palette.diagnostic.info, palette.diff.change),
      blocked = status(palette.diagnostic.warning),
      failed = status(palette.diagnostic.error, palette.diff.delete),
      done = status(palette.diagnostic.ok, palette.diff.add),
      ready = idle(),
      unknown = idle(),
    },
    terminal = {
      background = palette.bg.editor,
      foreground = palette.fg.base,
      selection = palette.ui.visual,
      cursor_color = palette.ui.cursor,
      ansi = ansi,
    },
  }
end
