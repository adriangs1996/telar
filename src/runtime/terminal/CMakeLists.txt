telar_add_domain(runtime terminal
  EXCLUDE graphics command_capture shell_integration
  SOURCES
    control/checksum/checksum.cpp
    control/clipboard/clipboard.cpp
    control/control.cpp
    control/engine/engine.cpp
    control/glyph/glyph.cpp
    control/graphics_payload.cpp
    control/pty_response_queue.cpp
    control/vt_state.cpp
    ghostty/ghostty.cpp
    graphics_storage/graphics_storage.cpp
    kitty/kitty.cpp
    osc_scanner/osc_scanner.cpp
    png_decoder.cpp
    text_reader/cell_projection.cpp
    text_reader/text_reader.cpp
  DEPS diagnostics host)
# The grid includes the cell layout the build reads from libghostty-vt.
add_dependencies(runtime-terminal cell-layout)

if(BUILD_TESTING)
  telar_add_domain_tests(terminal LINK telar::base telar::config telar::platform telar::vocabulary telar::wire)
  target_compile_options(runtime-terminal-tests PRIVATE -Wall -Wextra -Wpedantic)
endif()
