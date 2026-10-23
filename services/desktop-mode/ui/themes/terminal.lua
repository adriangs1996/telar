-- Native terminal defaults from src/model/appearance/TerminalTheme.zig.
return require("theme_palette")({
  wallpaper = "vesper-city-pierre-blue.png",
  bg = {
    editor = "#18181b",
    window = "#18181b",
    inset = "#000000",
  },
  fg = {
    base = "#e5e5e5",
    fg2 = "#e5e5e5",
    fg3 = "#666666",
  },
  border = {
    editor = "#666666",
    elevated = "#e5e5e5",
  },
  accent = {
    primary = "#2472c8",
    contrast = "#18181b",
  },
  diagnostic = {
    info = "#2472c8",
    warning = "#e5e510",
    error = "#f14c4c",
    ok = "#0dbc79",
  },
  diff = {
    add = "#16392e",
    change = "#1a2635",
    delete = "#432225",
  },
  ui = {
    visual = "#666666",
    cursorline = "#666666",
    cursor = "#e5e5e5",
  },
  ansi = {
    black = "#000000",
    red = "#cd3131",
    green = "#0dbc79",
    yellow = "#e5e510",
    blue = "#2472c8",
    magenta = "#bc3fbc",
    cyan = "#11a8cd",
    white = "#e5e5e5",
    brightBlack = "#666666",
    brightRed = "#f14c4c",
    brightGreen = "#23d18b",
    brightYellow = "#f5f543",
    brightBlue = "#3b8eea",
    brightMagenta = "#d670d6",
    brightCyan = "#29b8db",
    brightWhite = "#ffffff",
  },
})
