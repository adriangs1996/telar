cmake_minimum_required(VERSION 4.4.5)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_lua LANGUAGES C CXX)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/cpp_modules.cmake")

if(NOT TARGET telar-client)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-client" "${CMAKE_BINARY_DIR}/telar-client")
endif()

set(TELAR_LUA_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../vendor/lua-5.5.1/src")
set(TELAR_LUA_NAMES
  lapi lauxlib lbaselib lcode lcorolib lctype ldebug ldo ldump lfunc lgc
  llex lmathlib lmem lobject lopcodes lparser lstate lstring lstrlib ltable
  ltablib ltm lundump lutf8lib lvm lzio)
set(TELAR_LUA_SOURCES)
foreach(name IN LISTS TELAR_LUA_NAMES)
  list(APPEND TELAR_LUA_SOURCES "${TELAR_LUA_SOURCE_DIR}/${name}.c")
endforeach()

# Lua's C++ exception mode unwinds C++ callback resources on Lua errors.
set_source_files_properties(${TELAR_LUA_SOURCES} PROPERTIES LANGUAGE CXX)
add_library(telar-lua-vm STATIC ${TELAR_LUA_SOURCES})
target_include_directories(telar-lua-vm SYSTEM PUBLIC "${TELAR_LUA_SOURCE_DIR}")
target_compile_definitions(telar-lua-vm PRIVATE LUA_USE_POSIX)

add_library(telar-lua STATIC)
add_library(telar::lua ALIAS telar-lua)
telar_modules(telar-lua)
target_include_directories(telar-lua PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-lua PUBLIC telar-lua-vm telar::base telar::client)

telar_editor_flags(telar-lua)
