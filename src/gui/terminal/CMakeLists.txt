telar_add_domain(gui terminal
  SOURCES
    font_grid/font_grid.cpp
    glyphs/curve_cache/box_curve.cpp
    glyphs/curve_cache/curve_cache.cpp
    glyphs/glyphs.cpp
    row_cache/row_cache.cpp
    selection/selection.cpp
  DEPS core)
set_source_files_properties(glyphs/curve_cache/box_curve.cpp PROPERTIES COMPILE_OPTIONS -ffp-contract=off)
