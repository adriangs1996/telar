-- Neovim reference: kanagawa/palettes/dragon.lua.
return require("theme_palette")({
  wallpaper = "kanagawa-dragon-city.png",
  bg = {
    editor = "#181616",
    window = "#1D1C19",
    inset = "#282727",
  },
  fg = {
    base = "#c5c9c5",
    fg2 = "#9e9b93",
    fg3 = "#737c73",
  },
  border = {
    editor = "#393836",
    elevated = "#54546D",
  },
  accent = {
    primary = "#8ba4b0",
    contrast = "#181616",
  },
  diagnostic = {
    info = "#658594",
    warning = "#FF9E3B",
    error = "#E82424",
    ok = "#98BB6C",
  },
  diff = {
    add = "#2B3328",
    change = "#252535",
    delete = "#43242B",
  },
  ui = {
    visual = "#223249",
    cursorline = "#393836",
    cursor = "#8ba4b0",
  },
  ansi = {
    black = "#0d0c0c",
    red = "#c4746e",
    green = "#8a9a7b",
    yellow = "#c4b28a",
    blue = "#8ba4b0",
    magenta = "#a292a3",
    cyan = "#8fa49e",
    white = "#C8C093",
    brightBlack = "#a6a69c",
    brightRed = "#E46876",
    brightGreen = "#87a987",
    brightYellow = "#E6C384",
    brightBlue = "#7FB4CA",
    brightMagenta = "#938AA9",
    brightCyan = "#7AA89F",
    brightWhite = "#c5c9c5",
  },
})
