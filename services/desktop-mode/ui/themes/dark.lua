-- The default theme. Every other theme is applied on top of it, so this file also defines
-- which tokens exist: a theme can only change a token named here, and must keep its type.
return {
  colors = {
    -- Behind every surface, where no wallpaper image covers it.
    ground = "#0C0B10",
    -- Topbar, sidebar and other chrome panels.
    chrome = "#15131B",
    -- Rows, cards and pane headers on top of chrome.
    raised = "#1C1924",
    hover = "#24202E",
    selected = "#262131",
    border = "#2A2634",
    border_strong = "#3A3447",
    text = "#ECE8F3",
    muted = "#A39CB0",
    -- Small uppercase section labels.
    label = "#8B849A",
    accent = "#B9A2F0",
    -- Text drawn on an accent fill.
    on_accent = "#15131B",
    error = "#FF8A80",
  },

  -- One set per agent status: `color` for glyphs and dots, `text` and `background` for chips,
  -- `border` for the pane of an agent in that status.
  status = {
    working = {
      color = "#7FB0FF",
      text = "#A9C8FF",
      background = "#1A2233",
      border = "#35507A",
    },
    blocked = {
      color = "#F5B759",
      text = "#F5C178",
      background = "#2A2219",
      border = "#6B5228",
    },
    failed = {
      color = "#FF8A80",
      text = "#FFB0A8",
      background = "#2D1A1A",
      border = "#7A3A36",
    },
    done = {
      color = "#5FBF8A",
      text = "#93DDB0",
      background = "#18261F",
      border = "#2F6B4A",
    },
    ready = {
      color = "#8B849A",
      text = "#A39CB0",
      background = "#1C1924",
      border = "#2A2634",
    },
    unknown = {
      color = "#8B849A",
      text = "#A39CB0",
      background = "#1C1924",
      border = "#2A2634",
    },
  },

  terminal = {
    background = "#0F0E14",
    foreground = "#D7D2E0",
    selection = "#3A3050",
    ansi = {
      black = "#2A2634",
      red = "#FF8A80",
      green = "#8FD6A6",
      yellow = "#F5C178",
      blue = "#8DB8FF",
      magenta = "#C9B8F5",
      cyan = "#8FD3D6",
      white = "#D7D2E0",
      bright_black = "#4A4458",
      bright_red = "#FFA59D",
      bright_green = "#A9E3BC",
      bright_yellow = "#F8D29A",
      bright_blue = "#A9C8FF",
      bright_magenta = "#DCCFFA",
      bright_cyan = "#A8E2E4",
      bright_white = "#F2EFF7",
    },
    -- The same settings as the GUI's `gui.font`. An empty family uses the bundled JetBrains
    -- Mono; graphemes the face lacks fall back to it, then to the bundled Nerd Font symbols,
    -- then to the system's fonts.
    font = {
      family = "",
      -- The face's style name, such as "Light" or "Medium"; empty is the regular face.
      style = "",
      -- Logical pixels, 6..96; decimals allowed.
      size = 15,
      -- Multiplier of the font's natural line height, 0.75..3.
      line_height = 1,
      -- Extra logical pixels per cell, -5..20.
      letter_spacing = 0,
    },
  },

  -- Font families for the chrome; an empty `ui` uses the system's. JetBrains Mono is bundled.
  fonts = {
    ui = "",
    mono = "JetBrains Mono",
  },

  radius = {
    small = 6,
    medium = 10,
    large = 14,
  },
}
