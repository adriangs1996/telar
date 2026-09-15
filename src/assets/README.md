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

`TelarNerdIcons-Regular.ttf` is a 7,352-byte subset of
`SymbolsNerdFontMono-Regular.ttf` from Nerd Fonts v3.5.1. It contains only the
27 icon glyphs used by the embedded `nerd-font` icon theme. The source release
archive SHA-256 is
`01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996`;
the source TTF SHA-256 is
`fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749`;
and the subset SHA-256 is
`ce4e73f3c996fbeb829a080cde56172888a6c30c8bee2eb2dafea8443e47d7ac`.
`NerdFonts-LICENSE.txt` and `NerdFonts-README.md` record the license and
upstream attribution shipped in the release archive.

The GUI additionally embeds the complete `SymbolsNerdFontMono-Regular.ttf`
from [Nerd Fonts v3.5.1](https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1)
as a missing-glyph fallback. It retains the configured font for covered text;
the TUI continues using the small `TelarNerdIcons-Regular.ttf` subset above.
The full face is 2,610,012 bytes and has the source TTF SHA-256 above. It can
be reproduced by downloading
`https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.zip`
(SHA-256 `fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc`)
and extracting `SymbolsNerdFontMono-Regular.ttf` without modification. The
same bundled Nerd Fonts license and attribution apply.

The subset includes U+E62B (`custom-vim`) and U+E702 (`dev-git`) for foreground
application tabs. It is reproducible with fonttools 4.63.0:

```sh
SOURCE_DATE_EPOCH=1787335283 pyftsubset SymbolsNerdFontMono-Regular.ttf \
  --output-file=TelarNerdIcons-Regular.ttf \
  --unicodes=U+E62B,U+E702,U+EA76,U+EACD,U+EB53,U+F4BC,U+EFC5,U+F240-F244,U+EC20,U+EA85,U+EB32,U+EE06-EE09,U+EA6C,U+EBB3,U+EBA4,U+EA87,U+EAB5-EAB6,U+EB4C,U+F03FF \
  --layout-features='*' --name-IDs='*' --name-legacy \
  --name-languages='*' --notdef-glyph --recommended-glyphs
```

`IBMPlexSans-Regular.ttf` (200,500 bytes) and `IBMPlexSans-SemiBold.ttf`
(202,632 bytes) are the GUI's embedded proportional chrome face. They are the
static complete TTFs from IBM Plex release
[`@ibm/plex-sans@1.1.0`](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-sans%401.1.0),
downloaded on 2026-09-14 from
`https://github.com/IBM/plex/releases/download/%40ibm%2Fplex-sans%401.1.0/ibm-plex-sans.zip`
(SHA-256 `fb365d910566e6d199cc2c15579a7dd9a267128e18431a394ed81f1970c69200`)
as `ibm-plex-sans/fonts/complete/ttf/IBMPlexSans-Regular.ttf` and
`IBMPlexSans-SemiBold.ttf` without modification. Their SHA-256 are
`975dcda37d80f038dcd143c22e33ca2d97a0cc5a929aace1c749153b0fe1afa5` and
`a20caf8286023a6a7a85e40b1d2a4ae9fc3e3b1f9eda8f4c542dd4986af67bb1`.
The fonts are distributed under the SIL Open Font License 1.1 with Reserved
Font Name "Plex"; the release's `LICENSE.txt` is copied verbatim as
`IBMPlexSans-OFL.txt`. Only native chrome labels use these faces; terminal
cells never select them.

The original app icons below are retained as source assets. Both adapters now
embed the T3 Code provider atlas described below.

`Claude.png` was downloaded on 2026-08-26 from the Apple touch icon linked by
Anthropic's official Claude download page. It is a 256 x 256 RGBA PNG with
SHA-256
`1bec5f7b12a4a46fea879633464ebf1d32144ef731a0f054539b2d7251871cb6`.

`Codex.png` is `Contents/Resources/icon-chatgpt.png` from the official Codex
macOS disk image downloaded on 2026-08-26. The application identifies itself
as `com.openai.codex`, version `26.820.60940` build `7119`, and is signed by
`Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)`. The source DMG
SHA-256 is
`6545f82798df8e6ceaba1dad1d2aed3bb71b97545b342a5916b70d7732931c5c`;
the extracted 2048 x 2048 RGBA PNG SHA-256 is
`3453947a9ce2709b7ec51c0559c7eb976e4ac53b232b607d1d81b0d1d1048b61`.

`Pi.svg` is the square badge from the Pi press kit, downloaded on 2026-09-02
from `https://pi.dev/favicon.svg`. The press kit describes it as the square
mark for favicons and compact badges; the primary logo at
`https://pi.dev/logo.svg` is a white mark without a background and would
vanish on light terminals. Its SHA-256 is
`a5624bc3b8cac94de75f6f13701eca2ad3ef67bbeba286c4af3f398806f0858a`.
Pi is published by Earendil Inc. under the MIT License.

`Pi.png` is the 256 x 256 RGBA rasterization of `Pi.svg` with SHA-256
`9397ec24ab94be1917b12fac5748baf0e70bbf6c25f79b00e4960f5b1906d22b`. It is
reproducible with librsvg 2.62.3:

```sh
rsvg-convert -w 256 -h 256 -f png -o Pi.png Pi.svg
```

Official sources and usage terms:

- <https://claude.ai/download>
- <https://cdn.prod.website-files.com/6889473510b50328dbb70ae6/68c33859cc6cd903686c66a2_apple-touch-icon.png>
- <https://openai.com/codex/for-work/>
- <https://persistent.oaistatic.com/codex-app-prod/Codex.dmg>
- <https://openai.com/brand/>
- <https://pi.dev/press-kit>
- <https://pi.dev/favicon.svg>
- <https://github.com/earendil-works/pi/blob/main/LICENSE>

`telar-mark.svg` is Telar's own mark, the small variant of the icon designed
for sizes at or below 32 px: three warp threads and one weft carrying the
shuttle, on the rounded container. Its SHA-256 is
`2bd0d0ad77297ac92076edf19f487313e6a32c56bb525d6593a36ab85c7e921c`.

`telar-mark-64.png` is its 64 x 64 RGBA rasterization with SHA-256
`514ff1658c1f3ee191827624bdf39865e367a3afb090341343b62f69cde1785c`,
reproducible with librsvg 2.62.3:

```sh
rsvg-convert -w 64 -h 64 -f png -o telar-mark-64.png telar-mark.svg
```

`telar-mark-64.rgba` is the raw straight-alpha RGBA of that PNG, SHA-256
`c1cd678c75399de6171cd9975927ced073a9043a9131f92fb3f27c7f2935d2dd`.
`tools/build_telar_mark.py` rebuilds it with Pillow 12.2.0. The top bar
box-filters it into the icon atlas at cell size, sixteen premultiplied-alpha
bilinear taps per pixel, and keeps its alpha so the host composes it over
whatever it paints behind the bar.

## Sidebar provider symbols

`provider-symbols-192x64.rgba` contains three 64 × 64 RGBA symbols in
Claude, OpenAI, Pi order. Its SHA-256 is
`e2cec9fa09ee6ae7f47dccf770f75f3e574f2e1e95a95d263278aa432378135d`.
Both adapters embed this 49,152-byte atlas. The GUI box-filters the symbols
into its existing sprite page, premultiplies them, and draws them at 60%
opacity. OpenAI follows the theme's `text` color; Claude and Pi retain their
source colors. Tint and opacity are quad attributes; changing selection or theme does not rebuild
or upload the symbols. Workspace favicons retain their own colors.

The TUI resamples the same 64 px slots with premultiplied-alpha bilinear
filtering and centers each symbol inside the terminal cell aspect ratio.
OpenAI follows the sidebar foreground. A foreground change rebuilds and
retransmits the existing atlas without reallocating it; an unchanged frame
does neither. Terminals without KGP retain the existing cell glyphs.

`Claude-symbol.svg` and `OpenAI-symbol.svg` preserve the path and viewBox of
`ClaudeAI` and `OpenAI` in
[T3 Code's Icons.tsx](https://github.com/pingdotgg/t3code/blob/9375c779707fb95c06670db6da87441720b2d2e2/apps/web/src/components/Icons.tsx),
retrieved on 2026-09-14. The retrieved file SHA-256 is
`d5e70eeecb8d930c4976f1d302b401c90ac0d78cc2becb4d23e522a7ed8b2354`.
OpenAI uses white for tinting and Claude retains its orange fill. The complete
upstream MIT notice is in `T3-Icons-LICENSE.txt`. `Pi-symbol.svg` matches `PiAgentIcon` in the same
revision, including its black background and 160-unit corner radius.

Regenerate with librsvg 2.62.3 and Pillow 12.2.0:

```sh
uv run --no-project --with pillow==12.2.0 python tools/build_provider_symbols.py
```
