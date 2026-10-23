-- Neovim reference: cybervenom/palette.lua.
return require("theme_palette")({
  wallpaper = "ghostwire-neon-skyline.png",
  bg = {
    editor = "#211b2f",
    window = "#1a1627",
    inset = "#312b3e",
  },
  fg = {
    base = "#aba8b6",
    fg2 = "#8e899d",
    fg3 = "#5e5d74",
  },
  border = {
    editor = "#373245",
    elevated = "#58506c",
  },
  accent = {
    primary = "#aa87f5",
    contrast = "#211b2f",
  },
  diagnostic = {
    info = "#8caaee",
    warning = "#d9cc7e",
    error = "#f37986",
    ok = "#5fb095",
  },
  diff = {
    add = "#2d3943",
    change = "#33334d",
    delete = "#4b2e40",
  },
  ui = {
    visual = "#433661",
    cursorline = "#131220",
    cursor = "#aa87f5",
  },
  ansi = {
    black = "#383546",
    red = "#f37986",
    green = "#5fb095",
    yellow = "#d9cc7e",
    blue = "#8caaee",
    magenta = "#aa87f5",
    cyan = "#82c3d3",
    white = "#aba8b6",
    brightBlack = "#7c7690",
    brightRed = "#fea9af",
    brightGreen = "#99c2ac",
    brightYellow = "#e5ca93",
    brightBlue = "#b8d2ff",
    brightMagenta = "#c7b2ff",
    brightCyan = "#85c1dc",
    brightWhite = "#e5e3ee",
  },
})
