-- Neovim reference: vesper/init.lua, dark palette.
return require("theme_palette")({
  wallpaper = "vesper-city.png",
  bg = {
    editor = "#101010",
    window = "#161616",
    inset = "#232323",
  },
  fg = {
    base = "#ffffff",
    fg2 = "#a0a0a0",
    fg3 = "#7e7e7e",
  },
  border = {
    editor = "#282828",
    elevated = "#282828",
  },
  accent = {
    primary = "#ffc799",
    contrast = "#101010",
  },
  diagnostic = {
    info = "#aca1cf",
    warning = "#e6b99d",
    error = "#ff8080",
    ok = "#99ffe4",
  },
  diff = {
    add = "#293b36",
    change = "#362d26",
    delete = "#3b2424",
  },
  ui = {
    visual = "#584739",
    cursorline = "#241f1c",
    cursor = "#ffc799",
  },
  ansi = {
    black = "#101010",
    red = "#f5a191",
    green = "#90b99f",
    yellow = "#e6b99d",
    blue = "#aca1cf",
    magenta = "#e29eca",
    cyan = "#ea83a5",
    white = "#a0a0a0",
    brightBlack = "#7e7e7e",
    brightRed = "#ff8080",
    brightGreen = "#99ffe4",
    brightYellow = "#ffc799",
    brightBlue = "#b9aeda",
    brightMagenta = "#ecaad6",
    brightCyan = "#f591b2",
    brightWhite = "#ffffff",
  },
})
