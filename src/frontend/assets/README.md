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

`TelarNerdIcons-Regular.ttf` is a 6,340-byte subset of
`SymbolsNerdFontMono-Regular.ttf` from Nerd Fonts v3.5.1. It contains only the
23 icon glyphs used by the embedded `nerd-font` icon theme. The source release
archive SHA-256 is
`01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996`;
the source TTF SHA-256 is
`fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749`;
and the subset SHA-256 is
`57ff2655b3504721c5147804b02f04c70b1abbec0b715f4f6f24d0e4aea98d0e`.
`NerdFonts-LICENSE.txt` and `NerdFonts-README.md` record the license and
upstream attribution shipped in the release archive.

The subset is reproducible with fonttools:

```sh
SOURCE_DATE_EPOCH=1787335283 pyftsubset SymbolsNerdFontMono-Regular.ttf \
  --output-file=TelarNerdIcons-Regular.ttf \
  --unicodes=U+EA76,U+EACD,U+EB53,U+F4BC,U+EFC5,U+F240-F244,U+EC20,U+EA85,U+EB32,U+EE06-EE09,U+EA6C,U+EBB3,U+EBA4,U+EA87,U+EAB5-EAB6 \
  --layout-features='*' --name-IDs='*' --name-legacy \
  --name-languages='*' --notdef-glyph --recommended-glyphs
```

`provider-marks-768x256.rgba` is the reproducible KGP provider atlas. Its three
256 x 256 RGBA slots contain official PNG assets in Claude, Codex, Pi order.
The atlas SHA-256 is
`2e2236e04ef2b1be9fa3da8fb63522fd969a90ad00710d098b0ac00f970279e0`.
`tools/build_provider_atlas.py` rebuilds it with Pillow 12.2.0 and Lanczos
resampling.

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

At runtime Telar downsamples the atlas's checked-in 256 px source slots with
premultiplied-alpha bilinear filtering. It centers the square artwork inside
slots that match the terminal cell aspect ratio, so a two-column by two-row
placement never stretches either logo.

Official sources and usage terms:

- <https://claude.ai/download>
- <https://cdn.prod.website-files.com/6889473510b50328dbb70ae6/68c33859cc6cd903686c66a2_apple-touch-icon.png>
- <https://openai.com/codex/for-work/>
- <https://persistent.oaistatic.com/codex-app-prod/Codex.dmg>
- <https://openai.com/brand/>
- <https://pi.dev/press-kit>
- <https://pi.dev/favicon.svg>
- <https://github.com/earendil-works/pi/blob/main/LICENSE>
