telar_add_domain(gui foundation/fonts
  SOURCES
    fonts-box_curve.cpp
    fonts-curve_cache.cpp
    fonts-glyphs.cpp
    fonts-text_runs.cpp
  MACOS_SOURCES
    fonts-glyph_rasterizer.cppm
  DEPS foundation/core foundation/text foundation/terminal)
set_source_files_properties(fonts-box_curve.cpp PROPERTIES COMPILE_OPTIONS -ffp-contract=off)
