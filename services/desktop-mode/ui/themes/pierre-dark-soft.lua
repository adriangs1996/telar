-- Neovim reference: pierre/init.lua, dark-soft palette.
return require("theme_palette")({
  wallpaper = "vesper-city-pierre-blue.png",
  bg = {
    editor = "#171717",
    window = "#101010",
    inset = "#262626",
  },
  fg = {
    base = "#d4d4d4",
    fg2 = "#8a8a8a",
    fg3 = "#636363",
  },
  border = {
    editor = "#262626",
    elevated = "#262626",
  },
  accent = {
    primary = "#69b1ff",
    contrast = "#171717",
  },
  diagnostic = {
    info = "#68cdf2",
    warning = "#ffd452",
    error = "#ff6762",
    ok = "#60d199",
  },
  diff = {
    add = "#24382e",
    change = "#24303c",
    delete = "#412525",
  },
  ui = {
    visual = "#30455d",
    cursorline = "#1b2c3e",
    cursor = "#69b1ff",
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
