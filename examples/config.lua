local telar = require("telar")

return telar.config({
  api_version = 2,

  runtime = {
    graphics = {
      pane_mib = 64,
      global_mib = 256,
    },
    proxy = {
      enabled = false,
      ca_dir = "state/proxy",
      intercept_hosts = {
        "api.anthropic.com",
        "api.openai.com",
        "chatgpt.com",
      },
    },
    -- Explicit opt-in: the first user request is sent through stdin to this
    -- command so it never appears in the process arguments.
    agent_descriptions = {
      command = {
        "codex", "exec", "--ephemeral", "--ignore-rules",
        "--skip-git-repo-check", "--model", "gpt-5.6-luna",
        "-c", 'model_reasoning_effort="low"', "-",
      },
      timeout_ms = 15000,
    },
    -- Explicit opt-in: one headless Pi kept alive in RPC mode between
    -- prompts. It serves the command suggestion palette (prefix+? or
    -- telar.action.suggest_command()), which sends the focused pane's
    -- working directory, its last visible rows and your request. Session
    -- titles keep using agent_descriptions. The child starts from "/" on
    -- the first prompt and is killed after idle_timeout_ms without work.
    engine = {
      command = {
        "pi", "--mode", "rpc", "--no-session", "--no-tools",
        "--no-extensions", "--no-skills", "--no-context-files",
      },
      timeout_ms = 20000,
      idle_timeout_ms = 300000,
    },
    -- Agent manifests: recognize, label and draw an agent without a rebuild.
    -- Naming a built-in ("claude", "codex", "pi") extends or overrides it.
    agents = {
      {
        name = "gemini",
        display_name = "Gemini CLI",
        placeholder = "New Gemini chat",
        icon = "G",
        process_names = { "gemini" },
        process_paths = { "/@google/gemini-cli/" },
        identity = { "gemini cli" },
        working = { "esc to cancel" },
        attachments = "ordered",
      },
      { name = "claude", working = { "brewing" } },
    },
  },

  plugins = {
    telar.plugin({ path = "plugins/sample" }),
  },

  client = {
    prefix = "ctrl+s",
    icons = "nerd-font",
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    sound = { enabled = true, ready = true, needs_input = true },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    bars = {
      bottom = {
        left = telar.bar.metrics(),
        center = telar.bar.tabs(),
        right = telar.bar.dynamic({
          every_ms = 1000,
          render = function(ctx)
            return {
              {
                text = string.format(
                  " %02d:%02d:%02d ",
                  ctx.time.hour,
                  ctx.time.minute,
                  ctx.time.second
                ),
                fg = "text",
                bold = true,
              },
            }
          end,
        }),
      },
      top = {
        right = telar.bar.static({
          { icon = "provider-codex", text = " telar ", fg = "accent", bold = true },
        }),
      },
    },
    keybindings = {
      telar.bind({ "[" }, telar.action.copy_mode()),
      telar.bind({ "%" }, telar.action.split_pane({ direction = "horizontal" })),
      telar.bind({ "s" }, function(ctx)
        return telar.action.toggle_sidebar()
      end),
      telar.bind_expr({ "h" }, function(ctx)
        return telar.input.key("left")
      end),
      telar.bind({ "shift+left" }, telar.action.resize_pane({ direction = "left" })),
      telar.bind({ "shift+right" }, telar.action.resize_pane({ direction = "right" })),
      telar.bind({ "shift+up" }, telar.action.resize_pane({ direction = "up" })),
      telar.bind({ "shift+down" }, telar.action.resize_pane({ direction = "down" })),
      telar.bind({ "alt+left" }, telar.action.resize_sidebar({ direction = "left" })),
      telar.bind({ "alt+right" }, telar.action.resize_sidebar({ direction = "right" })),
      telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
      telar.bind({ "w" }, telar.action.toggle_workspace_list()),
      telar.bind(
        { "p" },
        telar.action.plugin({ plugin = "dev.telar.sample", action = "toggle" })
      ),
    },
  },

  profiles = {
    remote = {
      client = {
        sidebar = { visible = false, renderer = "cells" },
      },
      runtime = {
        graphics = { pane_mib = 16, global_mib = 64 },
      },
    },
  },
})
