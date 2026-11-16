cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_git LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-platform)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../platform" "${CMAKE_BINARY_DIR}/telar-platform")
endif()

# zlib as the runtime links it: the managed static build on Linux, the SDK's copy on macOS.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/native.cmake")

if(NOT TARGET telar-native)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../native" "${CMAKE_BINARY_DIR}/telar-native")
endif()
if(NOT TARGET telar-git-checkout)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/checkout" "${CMAKE_BINARY_DIR}/telar-git-checkout")
endif()

add_library(telar-git STATIC git.cpp git-config.cpp git-format.cpp git-history.cpp git-objects.cpp git-worktree.cpp)
add_library(telar::git ALIAS telar-git)
telar_modules(telar-git EXCLUDE checkout)
target_link_libraries(telar-git PUBLIC telar::platform telar::git-checkout telar::native OpenSSL::Crypto deps::zlib)
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
