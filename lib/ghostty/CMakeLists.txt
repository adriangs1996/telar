# Only libghostty-vt's headers and calls into their static inline helpers: each process that
# calls into the library links it itself.
# libghostty-vt's headers as ordinary include directories, not system ones: the projects that
# link the library get them from deps::ghostty_vt as system headers.
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/deps/ghostty.cmake")
# Not checked for lifetimes: the Wuffs header that wuffs/ wraps fails the analysis.
telar_add_library(telar-ghostty
  SOURCES wuffs/wuffs.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include" "$<TARGET_PROPERTY:deps::ghostty_vt,INTERFACE_INCLUDE_DIRECTORIES>"
  CHECKS lint blank_lines interface_bodies)
