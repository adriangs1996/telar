-- nvim --headless --clean -l integrations/nvim/tests/navigate_test.lua
-- A move crosses Neovim's windows first and asks telar for the next pane only at the edge.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

vim.opt.rtp:prepend(root)
vim.env.TELAR_BIN_PATH = "/opt/telar/bin/telar"

local failures = 0

local function check(condition, message)
  if not condition then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end

local commands = {}

vim.system = function(command)
  table.insert(commands, command)
end

local navigate = require("telar.navigate")

-- The new window opens on the left, with the cursor.
vim.cmd.vsplit()

local left = vim.api.nvim_get_current_win()

navigate.move("right")
check(vim.api.nvim_get_current_win() ~= left, "a move to the right reaches the window on the right")
check(#commands == 0, "telar is not asked while a window is that way")
navigate.move("right")
check(#commands == 1, "at the edge telar is asked for the pane that way")
check(vim.deep_equal(commands[1], { "/opt/telar/bin/telar", "pane", "focus", "--current", "--direction", "right", "--json" }), "the pane's telar focuses the pane to the right")
navigate.map({ up = "<M-k>" })
check(vim.fn.maparg("<C-h>", "n") ~= "" and vim.fn.maparg("<M-k>", "n") ~= "", "the default keys map, and a key given replaces its direction's")
check(not pcall(navigate.move, "sideways"), "an unknown direction is refused")

if failures > 0 then
  os.exit(1)
end

print("navigate_test: ok")
