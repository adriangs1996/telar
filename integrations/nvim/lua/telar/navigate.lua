-- Moves between Neovim windows and, past the edge of the last one, to the telar pane beside this
-- one.
local M = {}

local wincmds = { left = "h", down = "j", up = "k", right = "l" }

-- Moves the cursor one window towards `direction` (left, down, up or right); at the edge, asks
-- telar to focus the pane that way.
function M.move(direction)
  local wincmd = assert(wincmds[direction], "telar: unknown direction " .. tostring(direction))
  local window = vim.api.nvim_get_current_win()

  vim.cmd.wincmd(wincmd)
  if vim.api.nvim_get_current_win() == window then
    vim.system({ require("telar").bin(), "pane", "focus", "--current", "--direction", direction, "--json" })
  end
end

M.default_keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" }

-- Maps `keys` (a direction to a normal mode key, the defaults otherwise) to the moves.
function M.map(keys)
  for direction, key in pairs(vim.tbl_extend("force", M.default_keys, keys or {})) do
    vim.keymap.set("n", key, function()
      M.move(direction)
    end, { desc = "Move " .. direction .. " across Neovim and telar" })
  end
end

return M
