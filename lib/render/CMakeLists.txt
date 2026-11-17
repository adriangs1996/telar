# The Markdown parser, compiled as upstream ships it.
set(TELAR_MD4C_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../vendor/md4c-0.6.0/src")
add_library(telar-render-md4c STATIC "${TELAR_MD4C_SOURCE_DIR}/md4c.c" "${TELAR_MD4C_SOURCE_DIR}/entity.c")
target_include_directories(telar-render-md4c SYSTEM PUBLIC "${TELAR_MD4C_SOURCE_DIR}")
set_target_properties(telar-render-md4c PROPERTIES C_STANDARD 99 POSITION_INDEPENDENT_CODE ON)
target_link_libraries(telar-render-md4c PRIVATE telar::build_flags)

telar_add_library(telar-render
  SOURCES document/document.cpp markdown/markdown.cpp terminal/terminal.cpp
  DEPS telar::base telar-render-md4c)
target_compile_options(telar-render PRIVATE ${TELAR_WARNINGS})

if(BUILD_TESTING)
  telar_add_tests(telar-render-tests LABEL lib.render LINK telar::render)
  target_compile_options(telar-render-tests PRIVATE ${TELAR_WARNINGS})
endif()
