local telar = require("telar")

return telar.config({
  api_version = 2,

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
    prefix = "ctrl+s",
    theme = telar.theme({
      base = "vesper",
      colors = { accent = "#ffc799" },
    }),
    sidebar = { visible = true, renderer = "automatic" },
    input = { escape_timeout_ms = 25, sequence_timeout_ms = 1000 },
    keybindings = {
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
      telar.bind({ "z" }, telar.action.toggle_pane_fullscreen()),
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
