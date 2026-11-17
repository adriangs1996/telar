telar_add_domain(runtime graphics
  SOURCES
    file_input/file_input.cpp
    pane_media/pane_media.cpp
    prepared_images/prepared_images.cpp
    synchronizer/synchronizer.cpp
  DEPS diagnostics transport terminal)

if(BUILD_TESTING)
  telar_add_domain_tests(graphics LINK telar::base telar::config telar::platform telar::vocabulary telar::wire)
endif()
