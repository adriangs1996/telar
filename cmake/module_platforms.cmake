# Native-only interfaces; portable facades guard their native declarations.
set(TELAR_MACOS_MODULES
  lib/sys/apple/apple.cppm
  src/gui/fonts/glyph_rasterizer/glyph_rasterizer.cppm
  src/runtime/platform/frameworks/frameworks.cppm
  src/runtime/redirect/record/record.cppm
)
set(TELAR_LINUX_MODULES
  lib/sys/linux_api/linux_api.cppm
  src/runtime/platform/proc_file/proc_file.cppm
  src/gui/platform/background_effect/background_effect.cppm
)
