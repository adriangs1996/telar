local Direction = require('smart-splits.types').Direction

local direction_names = {
  [Direction.left] = 'left',
  [Direction.right] = 'right',
  [Direction.down] = 'down',
  [Direction.up] = 'up',
}

local reported_pane_id = nil

local function telar_bin()
  if vim.env.TELAR_BIN_PATH ~= nil and vim.env.TELAR_BIN_PATH ~= '' then
    return vim.env.TELAR_BIN_PATH
  end

  return 'telar'
end

local function telar_exec_json(arguments)
  local command = vim.deepcopy(arguments)
  table.insert(command, 1, telar_bin())
  local output, code = require('smart-splits.utils').system(command)
  if code ~= 0 or output == nil or #output == 0 then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    return nil
  end

  return decoded
end

---@type SmartSplitsMultiplexer
local M = {} ---@diagnostic disable-line: missing-fields

M.type = 'telar'

function M.current_pane_id()
  if reported_pane_id ~= nil then
    local pane_id = reported_pane_id
    reported_pane_id = nil
    return pane_id
  end

  if vim.env.TELAR_PANE_ID == nil or vim.env.TELAR_PANE_ID == '' then
    return nil
  end

  return tostring(vim.env.TELAR_PANE_ID)
end

function M.current_pane_at_edge(_direction)
  return false
end

function M.is_in_session()
  return vim.env.TELAR_PANE_ID ~= nil
    and vim.env.TELAR_PANE_ID ~= ''
    and vim.env.TELAR_PANE_GENERATION ~= nil
    and vim.env.TELAR_PANE_GENERATION ~= ''
end

function M.current_pane_is_zoomed()
  return false
end

function M.next_pane(direction)
  if not M.is_in_session() then
    return false
  end

  local name = direction_names[direction]
  if name == nil then
    return false
  end

  local result = telar_exec_json({ 'pane', 'focus', '--current', '--direction', name, '--json' })
  if result == nil or result.changed ~= true or result.focused_pane_id == nil then
    return false
  end

  reported_pane_id = tostring(result.focused_pane_id)
  return true
end

function M.resize_pane(_direction, _amount)
  return false
end

function M.split_pane(_direction, _size)
  return false
end

function M.update_mux_layout_details() end

return M
