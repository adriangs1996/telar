# Sidebar raster assets

`JetBrainsMono-Regular.ttf` is Telar's embedded UI rasterizer face. It is the
non-Nerd-Font regular face used by Ghostty's embedded-font build. Its SHA-256
is `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f`.
The font is distributed under the SIL Open Font License 1.1; the complete
license is in `JetBrainsMono-OFL.txt`.

Text rasterization links FreeType 2.13.2 from the source archive pinned in
`build.zig.zon`. Portions of this software are copyright © 2023 The FreeType
Project (<https://www.freetype.org>). All rights reserved. The upstream archive
contains the complete FreeType License and GPLv2 alternative.

Text shaping links HarfBuzz 11.0.0 from the source archive pinned in
`build.zig.zon`. Its complete Old MIT notice is in `HarfBuzz-COPYING.txt`.

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
