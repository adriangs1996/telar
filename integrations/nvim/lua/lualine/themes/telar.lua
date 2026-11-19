-- lualine's colors for telar's colorscheme, or its automatic ones before the theme arrives.
local tint = require("telar.tint")

if not tint.palette.telar then
  return require("lualine.themes.auto")
end

return tint.lualine_theme("telar")
