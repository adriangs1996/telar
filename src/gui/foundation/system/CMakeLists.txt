telar_add_domain(gui foundation/system
  SOURCES
    system-awake_clock.cpp
    system-file_stamp.cpp
    system-private_file_stamp.cpp
    system-secure_random.cpp
    system-shared_image_source.cpp
    system-wall_clock.cpp
  LINUX_SOURCES
    system-background_effect.cppm
  DEPS foundation/core)
