local M = {}

local default_keys = {
  left = '<C-h>',
  down = '<C-j>',
  up = '<C-k>',
  right = '<C-l>',
}

function M.setup(options)
  options = options or {}
  local smart_splits = require('smart-splits')
  local config = vim.tbl_deep_extend('force', {
    multiplexer_integration = 'telar',
  }, options.smart_splits or {})

  smart_splits.setup(config)
  if options.keymaps == false then
    return
  end

  local keys = vim.tbl_extend('force', default_keys, options.keys or {})
  vim.keymap.set('n', keys.left, smart_splits.move_cursor_left, { desc = 'Move left across Neovim and Telar' })
  vim.keymap.set('n', keys.down, smart_splits.move_cursor_down, { desc = 'Move down across Neovim and Telar' })
  vim.keymap.set('n', keys.up, smart_splits.move_cursor_up, { desc = 'Move up across Neovim and Telar' })
  vim.keymap.set('n', keys.right, smart_splits.move_cursor_right, { desc = 'Move right across Neovim and Telar' })
end

return M
