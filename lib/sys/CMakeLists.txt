find_package(Threads REQUIRED)

telar_add_library(telar-sys
  SOURCES posix/posix.cpp process/process.cpp socket/socket.cpp
  MACOS_SOURCES apple/apple.cppm apple/apple.cpp
  LINUX_SOURCES linux_api/linux_api.cppm linux_api/linux_api.cpp
  # The libraries that define what the modules declare.
  DEPS Threads::Threads ${CMAKE_DL_LIBS})
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-sys PRIVATE _GNU_SOURCE)
  target_link_libraries(telar-sys PUBLIC util)
endif()
target_compile_options(telar-sys PRIVATE ${TELAR_WARNINGS})

if(BUILD_TESTING)
  telar_add_tests(telar-sys-tests LABEL lib.sys LINK telar::sys)
  target_compile_options(telar-sys-tests PRIVATE ${TELAR_WARNINGS})
endif()
