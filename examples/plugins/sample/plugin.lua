local telar = require("telar")

return {
  actions = {
    toggle = function(ctx)
      return telar.action.toggle_sidebar()
    end,
  },
}
