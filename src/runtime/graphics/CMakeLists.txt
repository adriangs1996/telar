telar_add_domain(runtime graphics
  SOURCES
    file_input/file_input.cpp
    pane_media/pane_media.cpp
    png_decoder.cpp
    prepared_images/prepared_images.cpp
    synchronizer/synchronizer.cpp
  DEPS diagnostics transport terminal)
