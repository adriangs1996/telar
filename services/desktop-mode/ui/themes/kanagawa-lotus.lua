-- Neovim reference: kanagawa/palettes/lotus.lua.
return require("theme_palette")({
  wallpaper = "catppuccin-latte-wisteria.png",
  bg = {
    editor = "#f2ecbc",
    window = "#e5ddb0",
    inset = "#e7dba0",
  },
  fg = {
    base = "#545464",
    fg2 = "#4e8ca2",
    fg3 = "#8a8980",
  },
  border = {
    editor = "#e4d794",
    elevated = "#716e61",
  },
  accent = {
    primary = "#4d699b",
    contrast = "#f2ecbc",
  },
  diagnostic = {
    info = "#5a7785",
    warning = "#e98a00",
    error = "#e82424",
    ok = "#6f894e",
  },
  diff = {
    add = "#b7d0ae",
    change = "#d7e3d8",
    delete = "#d9a594",
  },
  ui = {
    visual = "#c9cbd1",
    cursorline = "#e4d794",
    cursor = "#4d699b",
  },
  ansi = {
    black = "#1F1F28",
    red = "#c84053",
    green = "#6f894e",
    yellow = "#77713f",
    blue = "#4d699b",
    magenta = "#b35b79",
    cyan = "#597b75",
    white = "#545464",
    brightBlack = "#8a8980",
    brightRed = "#d7474b",
    brightGreen = "#6e915f",
    brightYellow = "#836f4a",
    brightBlue = "#6693bf",
    brightMagenta = "#624c83",
    brightCyan = "#5e857a",
    brightWhite = "#43436c",
  },
})
