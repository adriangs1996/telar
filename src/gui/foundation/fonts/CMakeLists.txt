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

if(BUILD_TESTING AND TELAR_GUI_NATIVE)
  # Faces and shaping compile into gui-fonts-native, which only the native window builds.
  # font_cascade and row_text read the repository's fonts and share allocation_gate with
  # the application's tests.
  telar_add_domain_tests(foundation/fonts LINK gui-fonts-native gui-test-fixtures)
  target_compile_definitions(gui-foundation-fonts-tests PRIVATE TELAR_GUI_ASSETS_DIR="${TELAR_ROOT}/assets")
  target_compile_options(gui-foundation-fonts-tests PRIVATE -ffp-contract=off)
endif()
