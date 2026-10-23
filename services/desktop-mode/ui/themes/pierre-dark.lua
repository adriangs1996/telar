-- Neovim reference: pierre/init.lua, dark palette.
return require("theme_palette")({
  wallpaper = "vesper-city-pierre-blue.png",
  bg = {
    editor = "#0a0a0a",
    window = "#101010",
    inset = "#1d1d1d",
  },
  fg = {
    base = "#e5e5e5",
    fg2 = "#a3a3a3",
    fg3 = "#737373",
  },
  border = {
    editor = "#1d1d1d",
    elevated = "#1d1d1d",
  },
  accent = {
    primary = "#009fff",
    contrast = "#0a0a0a",
  },
  diagnostic = {
    info = "#08c0ef",
    warning = "#ffca00",
    error = "#ff2e3f",
    ok = "#07c480",
  },
  diff = {
    add = "#092b1f",
    change = "#082231",
    delete = "#361014",
  },
  ui = {
    visual = "#073754",
    cursorline = "#121b26",
    cursor = "#009fff",
  },
  ansi = {
    black = "#171717",
    red = "#ff2e3f",
    green = "#0dbe4e",
    yellow = "#ffca00",
    blue = "#009fff",
    magenta = "#e130ac",
    cyan = "#08c0ef",
    white = "#bcbcbc",
    brightBlack = "#737373",
    brightRed = "#ff2e3f",
    brightGreen = "#86c427",
    brightYellow = "#ffca00",
    brightBlue = "#009fff",
    brightMagenta = "#e130ac",
    brightCyan = "#08c0ef",
    brightWhite = "#bcbcbc",
  },
})
