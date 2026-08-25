# Sidebar raster assets

`provider-marks-128x64.rgba` is the KGP provider atlas. Each mark occupies a
64 x 64 RGBA slot:

- Columns 0-63 contain the Claude icon from Anthropic's newsroom press kit.
- Columns 64-127 contain `icon-codex-dark-color.png` from the official ChatGPT
  macOS application, resized from 1024 x 1024.

At runtime Telar resamples these square sources into a transparent atlas whose
slots follow the host terminal's cell aspect ratio. Kitty can then place each
slot across two rows and two columns without stretching the provider mark.

`claude-mark-64.rgba` remains as the lossless source used to rebuild the first
atlas slot.

Sources:

- <https://www.anthropic.com/news>
- <https://openai.com/codex/>
