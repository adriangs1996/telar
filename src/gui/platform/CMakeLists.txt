telar_add_domain(gui platform
  SOURCES
    awake_clock/awake_clock.cpp
    file_stamp/file_stamp.cpp
    notification_commands/notification_commands.cpp
    private_file_stamp/private_file_stamp.cpp
    progress_cosine/progress_cosine.cpp
    secure_random/secure_random.cpp
    shared_image_source/shared_image_source.cpp
    wall_clock/wall_clock.cpp
  LINUX_SOURCES
    background_effect/background_effect.cppm
  DEPS core text)
