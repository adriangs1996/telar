find_package(Threads REQUIRED)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

telar_add_library(telar-platform
  SOURCES primitives/primitives.cpp src/open_directory.c process/pipe_process.cpp process/pty_process.cpp src/trace.cpp daemon/daemon.cpp error/error.cpp events/events.cpp fs/fs.cpp graphics/graphics.cpp net/net.cpp sha256/sha256.cpp thread/thread.cpp paths/paths.cpp process/process.cpp
  MACOS_SOURCES listening/macos/listening.cpp
  LINUX_SOURCES listening/linux/listening.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::base telar::sys telar::vocabulary OpenSSL::Crypto Threads::Threads ${CMAKE_DL_LIBS})
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-platform PRIVATE _GNU_SOURCE)
  target_link_libraries(telar-platform PUBLIC util)
endif()
target_compile_options(telar-platform PRIVATE ${TELAR_WARNINGS})

if(BUILD_TESTING)
  telar_add_tests(telar-platform-tests LABEL lib.platform LINK telar::platform)
endif()
