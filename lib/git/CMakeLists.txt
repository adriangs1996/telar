# zlib as the runtime links it: the managed static build on Linux, the SDK's copy on macOS.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/native.cmake")

add_subdirectory(checkout)

telar_add_library(telar-git
  SOURCES git.cpp git-config.cpp git-format.cpp git-history.cpp git-objects.cpp git-worktree.cpp
  EXCLUDE checkout
  DEPS telar::platform telar::git-checkout telar::native OpenSSL::Crypto deps::zlib)
target_compile_options(telar-git PRIVATE -Wall -Wextra -Wpedantic)

if(BUILD_TESTING)
  add_executable(telar-git-tests tests/git_test.cpp)
  target_link_libraries(telar-git-tests PRIVATE telar::git)
  target_compile_options(telar-git-tests PRIVATE -Wall -Wextra -Wpedantic)
  add_test(NAME telar-git-tests COMMAND telar-git-tests)
  # The tests build repositories with the git CLI and skip without it.
  set_tests_properties(telar-git-tests PROPERTIES SKIP_RETURN_CODE 77 LABELS lib.git)
endif()
