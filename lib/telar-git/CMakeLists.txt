cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_git LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

# zlib as the runtime links it: the managed static build on Linux, the SDK's
# copy on macOS. A parent project that found it already is reused.
if(NOT ZLIB_LIBRARY)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/native_libraries.cmake")
  else()
    find_library(ZLIB_LIBRARY NAMES z PATHS "${CMAKE_OSX_SYSROOT}/usr/lib" NO_DEFAULT_PATH REQUIRED)
  endif()
endif()

add_library(telar-git STATIC)
add_library(telar::git ALIAS telar-git)
telar_modules(telar-git)
target_link_libraries(telar-git PUBLIC telar::platform OpenSSL::Crypto "${ZLIB_LIBRARY}")
if(TELAR_NATIVE_INCLUDE_DIR)
  target_include_directories(telar-git SYSTEM PUBLIC "${TELAR_NATIVE_INCLUDE_DIR}")
endif()
target_compile_options(telar-git PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-git)

if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
  if(BUILD_TESTING)
    add_executable(telar-git-tests tests/git_test.cpp)
    target_link_libraries(telar-git-tests PRIVATE telar::git)
    target_compile_options(telar-git-tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME telar-git-tests COMMAND telar-git-tests)
    # The tests build repositories with the git CLI and skip without it.
    set_tests_properties(telar-git-tests PROPERTIES SKIP_RETURN_CODE 77)
  endif()
endif()
