-- Neovim reference: osaka-jade/init.lua.
return require("theme_palette")({
  wallpaper = "osaka-jade-bg.jpg",
  bg = {
    editor = "#101010",
    window = "#161616",
    inset = "#232323",
  },
  fg = {
    base = "#d1d1cf",
    fg2 = "#a0a0a0",
    fg3 = "#7e7e7e",
  },
  border = {
    editor = "#282828",
    elevated = "#282828",
  },
  accent = {
    primary = "#A8C98C",
    contrast = "#111C18",
  },
  diagnostic = {
    info = "#91b7b0",
    warning = "#d4b477",
    error = "#e58c85",
    ok = "#91b99a",
  },
  diff = {
    add = "#272e29",
    change = "#282e24",
    delete = "#362625",
  },
  ui = {
    visual = "#304a39",
    cursorline = "#232323",
    cursor = "#c5e6a0",
  },
  ansi = {
    black = "#17241E",
    red = "#E58C85",
    green = "#91B99A",
    yellow = "#D4B477",
    blue = "#8FA9B3",
    magenta = "#B3A1B5",
    cyan = "#91B7B0",
    white = "#BBC8B5",
    brightBlack = "#7F9785",
    brightRed = "#F0A29A",
    brightGreen = "#A8C98C",
    brightYellow = "#D0C398",
    brightBlue = "#ABC1C8",
    brightMagenta = "#C4B3C5",
    brightCyan = "#ADD0C5",
    brightWhite = "#d1d1cf",
  },
})
