-- Neovim reference: plugins/tokyonight.lua and tokyonight.nvim, night palette.
return require("theme_palette")({
  wallpaper = "kanagawa-wave-city.png",
  bg = {
    editor = "#1a1b26",
    window = "#1a1b26",
    inset = "#292e42",
  },
  fg = {
    base = "#c0caf5",
    fg2 = "#a9b1d6",
    fg3 = "#565f89",
  },
  border = {
    editor = "#15161e",
    elevated = "#27a1b9",
  },
  accent = {
    primary = "#82aaff",
    contrast = "#1a1b26",
  },
  diagnostic = {
    info = "#0db9d7",
    warning = "#e0af68",
    error = "#db4b4b",
    ok = "#9ece6a",
  },
  diff = {
    add = "#243e4a",
    change = "#1f2231",
    delete = "#4a272f",
  },
  ui = {
    visual = "#283457",
    cursorline = "#292e42",
    cursor = "#c0caf5",
  },
  ansi = {
    black = "#15161e",
    red = "#f7768e",
    green = "#9ece6a",
    yellow = "#e0af68",
    blue = "#7aa2f7",
    magenta = "#bb9af7",
    cyan = "#7dcfff",
    white = "#a9b1d6",
    brightBlack = "#414868",
    brightRed = "#ff899d",
    brightGreen = "#9fe044",
    brightYellow = "#faba4a",
    brightBlue = "#8db0ff",
    brightMagenta = "#c7a9ff",
    brightCyan = "#a4daff",
    brightWhite = "#c0caf5",
  },
})
