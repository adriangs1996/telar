local telar = require("telar")

return telar.config({
  api_version = 1,

  runtime = {
    graphics = {
      pane_mib = 64,
      global_mib = 256,
    },
  },

  plugins = {
    telar.plugin({ path = "plugins/sample" }),
  },

  client = {
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    keybindings = {
      telar.bind({ "ctrl+b", "%" }, telar.action.split_pane({ direction = "horizontal" })),
      telar.bind({ "ctrl+b", "s" }, function(ctx)
        return telar.action.toggle_sidebar()
      end),
      telar.bind_expr({ "ctrl+b", "h" }, function(ctx)
        return telar.input.key("left")
      end),
      telar.bind(
        { "ctrl+b", "p" },
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
