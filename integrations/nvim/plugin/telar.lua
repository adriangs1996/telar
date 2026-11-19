-- Starts telar's integration in a telar pane; elsewhere it does nothing.
if vim.g.loaded_telar then
  return
end

vim.g.loaded_telar = true
require("telar").setup()
