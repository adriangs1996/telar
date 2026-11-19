-- The theme of the telar window showing this pane, read when the colorscheme is chosen.
local theme = require("telar.theme")
local current = theme.current or theme.read()

if not current then
  error("telar: no telar window gives this pane a theme", 0)
end

theme.apply(current, vim.g.telar_tint)
