cmake_minimum_required(VERSION 3.24)
project(telar_lua LANGUAGES C CXX)

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_BINARY_DIR}/telar-base")
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

add_library(telar-lua INTERFACE)
add_library(telar::lua ALIAS telar-lua)
target_include_directories(telar-lua INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(telar-lua INTERFACE telar-lua-vm telar::base)
