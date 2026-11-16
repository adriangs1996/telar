cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_render LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/TelarTargets.cmake")

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../base" "${CMAKE_BINARY_DIR}/telar-base")
endif()

# The Markdown parser, compiled as upstream ships it.
set(TELAR_MD4C_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../vendor/md4c-0.6.0/src")
add_library(telar-render-md4c STATIC "${TELAR_MD4C_SOURCE_DIR}/md4c.c" "${TELAR_MD4C_SOURCE_DIR}/entity.c")
target_include_directories(telar-render-md4c SYSTEM PUBLIC "${TELAR_MD4C_SOURCE_DIR}")
set_target_properties(telar-render-md4c PROPERTIES C_STANDARD 99 POSITION_INDEPENDENT_CODE ON)
target_link_libraries(telar-render-md4c PRIVATE telar::build_flags)

telar_add_library(telar-render
  SOURCES document/document.cpp markdown/markdown.cpp terminal/terminal.cpp
  DEPS telar::base telar-render-md4c)
target_compile_options(telar-render PRIVATE -Wall -Wextra -Wpedantic)

telar_editor_flags(telar-render)

if(PROJECT_IS_TOP_LEVEL)
  include(CTest)
  if(BUILD_TESTING)
    add_executable(telar-render-tests tests/render_test.cpp)
    target_link_libraries(telar-render-tests PRIVATE telar::render)
    target_compile_options(telar-render-tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME telar-render-tests COMMAND telar-render-tests)
  endif()
endif()
