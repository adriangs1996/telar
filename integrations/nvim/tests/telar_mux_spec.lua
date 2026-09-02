local root = assert(vim.env.TELAR_NVIM_INTEGRATION)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

package.preload['smart-splits.types'] = function()
  return { Direction = { left = 1, right = 2, down = 3, up = 4 } }
end

local configured = nil
package.preload['smart-splits'] = function()
  return {
    setup = function(options)
      configured = options
    end,
  }
end

local captured = nil
package.preload['smart-splits.utils'] = function()
  return {
    system = function(command)
      captured = command
      return '{"changed":true,"focused_pane_id":42,"reason":"focused"}\n', 0
    end,
  }
end

vim.env.TELAR_PANE_ID = '7'
vim.env.TELAR_PANE_GENERATION = '9'
vim.env.TELAR_BIN_PATH = '/tmp/telar'

local mux = require('smart-splits.mux.telar')
assert(mux.is_in_session())
assert(mux.current_pane_id() == '7')
assert(mux.next_pane(1))
assert(vim.deep_equal(captured, {
  '/tmp/telar',
  'pane',
  'focus',
  '--current',
  '--direction',
  'left',
  '--json',
}))
assert(mux.current_pane_id() == '42')
assert(mux.current_pane_id() == '7')

require('telar').setup({ keymaps = false })
assert(configured.multiplexer_integration == 'telar')
