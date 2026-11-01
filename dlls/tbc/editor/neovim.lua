return {
  {
    "mfussenegger/nvim-lint",
    opts = function()
      local lint = require("lint")

      local function resolve(root, path)
        if path:match("^/") or path:match("^%a:[/\\]") then
          return vim.fs.normalize(path)
        end
        return vim.fs.normalize(root .. "/" .. path)
      end

      local function project(bufnr)
        local filename = vim.api.nvim_buf_get_name(bufnr)
        local root = vim.fs.root(filename, { ".tbc.json" })
        if not root then
          return
        end
        local ok, config = pcall(function()
          return vim.json.decode(table.concat(vim.fn.readfile(root .. "/.tbc.json"), "\n"))
        end)
        if not ok or type(config) ~= "table" or type(config.linter) ~= "string" or (config.build_directory ~= nil and type(config.build_directory) ~= "string") then
          return
        end
        local source = filename
        local extension = vim.fn.fnamemodify(filename, ":e")
        if vim.tbl_contains({ "h", "hpp", "hh", "hxx", "ipp", "tpp" }, extension) then
          if type(config.header_translation_unit) ~= "string" then
            return
          end
          source = resolve(root, config.header_translation_unit)
        end
        return {
          root = root,
          command = vim.env.TBC_LINTER or resolve(root, config.linter),
          build = resolve(root, config.build_directory or "out/debug"),
          source = source,
        }
      end

      lint.linters.tbc = function()
        local config = assert(project(0), "No valid .tbc.json configuration")
        return {
          cmd = config.command,
          args = { "-p=" .. config.build, "--extra-arg=-fno-color-diagnostics", config.source },
          append_fname = false,
          stdin = false,
          stream = "stderr",
          ignore_exitcode = true,
          parser = require("lint.parser").from_pattern(
            "^(.+):(%d+):(%d+): (%w+): (.-) %[(tbc%-%S+)%]$",
            { "file", "lnum", "col", "severity", "message", "code" },
            { warning = vim.diagnostic.severity.WARN, error = vim.diagnostic.severity.ERROR },
            { source = "tbc-lint" }
          ),
        }
      end

      local function run(bufnr, explicit)
        local config = project(bufnr)
        if not config or vim.bo[bufnr].filetype ~= "cpp" then
          return
        end
        if vim.bo[bufnr].modified then
          if explicit then
            vim.notify("Save the buffer before running tbc-lint", vim.log.levels.WARN)
          end
          return
        end
        if vim.fn.executable(config.command) == 0 then
          if explicit then
            vim.notify("Build tbc-lint or set TBC_LINTER to its executable", vim.log.levels.WARN)
          end
          return
        end
        vim.api.nvim_buf_call(bufnr, function()
          lint.try_lint("tbc", { cwd = config.root })
        end)
      end

      -- Header checks use a configured translation unit to instantiate template bodies.
      vim.api.nvim_create_autocmd("BufWritePost", {
        group = vim.api.nvim_create_augroup("tbc-lint", { clear = true }),
        pattern = { "*.cpp", "*.cc", "*.cxx", "*.h", "*.hpp", "*.hh", "*.hxx", "*.ipp", "*.tpp" },
        callback = function(event)
          run(event.buf, false)
        end,
      })
      vim.api.nvim_create_user_command("TbcLint", function()
        run(vim.api.nvim_get_current_buf(), true)
      end, { desc = "Check inferred and explicit C++ lifetimes" })
    end,
  },
}
