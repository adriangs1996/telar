-- Neovim reference: catppuccin/palettes/frappe.lua and catppuccin/roles.lua.
return require("theme_palette")({
  wallpaper = "catppuccin-frappe-wisteria.png",
  bg = {
    editor = "#303446",
    window = "#292c3c",
    inset = "#414559",
  },
  fg = {
    base = "#c6d0f5",
    fg2 = "#a5adce",
    fg3 = "#838ba7",
  },
  border = {
    editor = "#51576d",
    elevated = "#737994",
  },
  accent = {
    primary = "#8caaee",
    contrast = "#303446",
  },
  diagnostic = {
    info = "#81c8be",
    warning = "#e5c890",
    error = "#e78284",
    ok = "#a6d189",
  },
  diff = {
    add = "#485353",
    change = "#3e465f",
    delete = "#554452",
  },
  ui = {
    visual = "#494e63",
    cursorline = "#3f4458",
    cursor = "#f2d5cf",
  },
  ansi = {
    black = "#51576d",
    red = "#e78284",
    green = "#a6d189",
    yellow = "#e5c890",
    blue = "#8caaee",
    magenta = "#f4b8e4",
    cyan = "#81c8be",
    white = "#a5adce",
    brightBlack = "#626880",
    brightRed = "#e67172",
    brightGreen = "#8ec772",
    brightYellow = "#d9ba73",
    brightBlue = "#7b9ef0",
    brightMagenta = "#f2a4db",
    brightCyan = "#5abfb5",
    brightWhite = "#b5bfe2",
  },
})
