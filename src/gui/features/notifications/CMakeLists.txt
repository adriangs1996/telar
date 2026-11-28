telar_add_domain(gui features/notifications
  SOURCES
    notifications.cpp
    notifications-alerts.cpp
    notifications-center.cpp
    notifications-commands.cpp
    notifications-limit_reports.cpp
    notifications-playback.cpp
    notifications-stack.cpp
    notifications-text.cpp
  DEPS foundation/core foundation/text foundation/model)

if(BUILD_TESTING)
  telar_add_domain_tests(features/notifications)
endif()
