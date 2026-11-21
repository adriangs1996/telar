-- telar's own Neovim configuration, for a host that has none. The runtime starts Neovim on it
-- with `-u` when the host has no ~/.config/nvim; a configuration made there later takes its
-- place. The plugins are the ones lazy-lock.json beside this file pins, fetched the first time
-- through whatever proxy the pane has. Without a network the editor starts all the same, with
-- the parsers Neovim ships and what telar itself teaches it.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local options = {
  number = true,
  relativenumber = false,
  signcolumn = "yes",
  cursorline = true,
  termguicolors = true,
  undofile = true,
  ignorecase = true,
  smartcase = true,
  splitright = true,
  splitbelow = true,
  expandtab = true,
  shiftwidth = 2,
  tabstop = 2,
  scrolloff = 4,
  updatetime = 250,
  timeoutlen = 400,
  wrap = false,
  showmode = false,
  laststatus = 3,
  completeopt = "menu,menuone,noselect",
}

for name, value in pairs(options) do
  vim.o[name] = value
end

-- The window's picker, which the runtime searches for: files, text and buffers.
vim.keymap.set("n", "<leader>f", "<Cmd>Telar files<CR>", { desc = "Find files" })
vim.keymap.set("n", "<leader>/", "<Cmd>Telar grep<CR>", { desc = "Search text" })
vim.keymap.set("n", "<leader>b", "<Cmd>Telar buffers<CR>", { desc = "Buffers" })
vim.keymap.set("n", "<Esc>", "<Cmd>nohlsearch<CR>")

-- Highlighting by the parsers Neovim has: the ones it ships, and any installed below.
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("TelarTreesitter", { clear = true }),
  callback = function(event)
    pcall(vim.treesitter.start, event.buf)
  end,
})

vim.diagnostic.config({ severity_sort = true, float = { border = "rounded" } })
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("TelarLsp", { clear = true }),
  callback = function(event)
    local function map(keys, action, description)
      vim.keymap.set("n", keys, action, { buffer = event.buf, desc = description })
    end

    map("gd", vim.lsp.buf.definition, "Go to definition")
    map("gr", vim.lsp.buf.references, "References")
    map("<leader>r", vim.lsp.buf.rename, "Rename")
    map("<leader>a", vim.lsp.buf.code_action, "Code action")
  end,
})

-- lazy.nvim, at the tag its own entry of the lockfile is of.
local lazy = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazy) then
  local output = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=v11.17.5", "https://github.com/folke/lazy.nvim.git", lazy })
  if vim.v.shell_error ~= 0 then
    vim.schedule(function()
      vim.notify("telar: the editor's plugins are not installed yet: " .. vim.trim(output), vim.log.levels.WARN)
    end)

    return
  end
end

vim.opt.rtp:prepend(lazy)

-- The language servers lspconfig knows that this host has on its PATH. None is installed here.
local servers = { "clangd", "lua_ls", "pyright", "rust_analyzer", "gopls", "ts_ls", "zls", "ruby_lsp", "bashls" }

require("lazy").setup({
  spec = {
    {
      "neovim/nvim-lspconfig",
      config = function()
        for _, server in ipairs(servers) do
          local configured = vim.lsp.config[server]
          local command = configured and configured.cmd
          if type(command) == "table" and vim.fn.executable(command[1]) == 1 then
            vim.lsp.enable(server)
          end
        end
      end,
    },
    { "lewis6991/gitsigns.nvim", opts = {} },
    {
      "hrsh7th/nvim-cmp",
      event = "InsertEnter",
      dependencies = { "hrsh7th/cmp-nvim-lsp", "hrsh7th/cmp-buffer" },
      config = function()
        local cmp = require("cmp")
        cmp.setup({
          mapping = cmp.mapping.preset.insert({
            ["<CR>"] = cmp.mapping.confirm({ select = false }),
            ["<Tab>"] = cmp.mapping.select_next_item(),
            ["<S-Tab>"] = cmp.mapping.select_prev_item(),
          }),
          sources = cmp.config.sources({ { name = "nvim_lsp" } }, { { name = "buffer" } }),
        })
      end,
    },
    {
      "nvim-treesitter/nvim-treesitter",
      branch = "main",
      lazy = false,
      build = function()
        -- More parsers than Neovim ships need its compiler: without one, the shipped ones stay.
        if vim.fn.executable("tree-sitter") == 1 and (vim.fn.executable("cc") == 1 or vim.fn.executable("gcc") == 1 or vim.fn.executable("clang") == 1) then
          require("nvim-treesitter").install({ "bash", "cpp", "go", "javascript", "json", "python", "ruby", "rust", "toml", "typescript", "yaml", "zig" })
        end
      end,
    },
  },
  lockfile = here .. "/lazy-lock.json",
  install = { colorscheme = {} },
  checker = { enabled = false },
  change_detection = { enabled = false },
  ui = { border = "rounded" },
})
