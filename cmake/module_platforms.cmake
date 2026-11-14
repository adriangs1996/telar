# Native-only interfaces; portable facades guard their native declarations.
set(TELAR_MACOS_MODULES
  lib/sys/apple/apple.cppm
  src/gui/fonts/glyph_rasterizer/glyph_rasterizer.cppm
  src/runtime/redirect/record/record.cppm
)
set(TELAR_LINUX_MODULES
  lib/sys/linux/linux.cppm
  src/gui/platform/background_effect/background_effect.cppm
)
