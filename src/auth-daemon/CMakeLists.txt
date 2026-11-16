project(telar_auth_daemon LANGUAGES CXX)

option(TELAR_AUTH_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The auth daemon supports macOS and Linux")
endif()

add_executable(telar-auth-daemon main.cpp)
target_link_libraries(telar-auth-daemon PRIVATE telar::build_flags)
target_compile_options(telar-auth-daemon PRIVATE -Wall -Wextra -Wpedantic)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-auth-daemon PRIVATE _GNU_SOURCE)
endif()
if(TELAR_AUTH_WARNINGS_AS_ERRORS)
  target_compile_options(telar-auth-daemon PRIVATE -Werror)
endif()
install(TARGETS telar-auth-daemon RUNTIME DESTINATION bin)

if(BUILD_TESTING)
  add_test(NAME auth-daemon-smoke COMMAND telar-auth-daemon)
  set_tests_properties(auth-daemon-smoke PROPERTIES TIMEOUT 10 LABELS auth)
endif()

telar_register_checks(telar-auth-daemon CHECKS lint lifetime)
