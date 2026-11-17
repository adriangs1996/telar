# zlib as the runtime links it: the managed static build on Linux, the SDK's copy on macOS.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/native.cmake")

add_subdirectory(checkout)

telar_add_library(telar-git
  SOURCES git.cpp git-config.cpp git-format.cpp git-history.cpp git-objects.cpp git-worktree.cpp
  EXCLUDE checkout
  DEPS telar::platform telar::git-checkout telar::native OpenSSL::Crypto deps::zlib)
target_compile_options(telar-git PRIVATE ${TELAR_WARNINGS})

if(BUILD_TESTING)
  telar_add_tests(telar-git-tests LABEL lib.git LINK telar::git)
  target_compile_options(telar-git-tests PRIVATE ${TELAR_WARNINGS})
endif()
