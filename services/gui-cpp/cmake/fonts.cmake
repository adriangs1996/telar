include(FetchContent)

file(READ "${TELAR_ROOT}/build.zig.zon" gui_dependency_manifest)
string(REGEX MATCH "[.]freetype[ \t\r\n]*=[ \t\r\n]*[.][{][ \t\r\n]*[.]url[ \t\r\n]*=[ \t\r\n]*\"([^\"]+)\"" gui_freetype_dependency "${gui_dependency_manifest}")
if(NOT gui_freetype_dependency)
  message(FATAL_ERROR "The FreeType dependency is missing from build.zig.zon")
endif()

FetchContent_Declare(telar_freetype
  URL "${CMAKE_MATCH_1}"
  URL_HASH SHA256=427201f5d5151670d05c1f5b45bef5dda1f2e7dd971ef54f0feaaa7ffd2ab90c
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR telar-source-only)
FetchContent_MakeAvailable(telar_freetype)

file(READ "${TELAR_ROOT}/build/freetype.zig" gui_freetype_build)
string(REGEX MATCH "const freetype_sources[^=]*=[^\\{]*\\{([^}]+)\\}" gui_freetype_source_list "${gui_freetype_build}")
if(NOT gui_freetype_source_list)
  message(FATAL_ERROR "The FreeType source list is missing from build/freetype.zig")
endif()

string(REGEX MATCHALL "\"[^\"]+[.]c\"" gui_freetype_source_names "${CMAKE_MATCH_1}")
set(gui_freetype_sources)
foreach(source IN LISTS gui_freetype_source_names)
  string(REPLACE "\"" "" source "${source}")
  list(APPEND gui_freetype_sources "${telar_freetype_SOURCE_DIR}/${source}")
endforeach()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND gui_freetype_sources "${telar_freetype_SOURCE_DIR}/builds/unix/ftsystem.c")
else()
  list(APPEND gui_freetype_sources "${telar_freetype_SOURCE_DIR}/src/base/ftsystem.c")
endif()
list(APPEND gui_freetype_sources "${telar_freetype_SOURCE_DIR}/src/base/ftdebug.c")

add_library(gui-freetype STATIC ${gui_freetype_sources})
target_include_directories(gui-freetype SYSTEM PUBLIC "${telar_freetype_SOURCE_DIR}/include")
target_compile_definitions(gui-freetype PRIVATE FT2_BUILD_LIBRARY HAVE_UNISTD_H HAVE_FCNTL_H)
set_target_properties(gui-freetype PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(gui-freetype INTERFACE "LINKER:--exclude-libs,$<TARGET_FILE_NAME:gui-freetype>")
endif()
if(TELAR_GUI_SANITIZERS)
  target_compile_options(gui-freetype PRIVATE -fsanitize=address -fno-omit-frame-pointer)
endif()

set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${TELAR_ROOT}/build.zig.zon" "${TELAR_ROOT}/build/freetype.zig")
install(FILES "${telar_freetype_SOURCE_DIR}/docs/FTL.TXT" DESTINATION share/licenses/telar-gui RENAME freetype.txt)

string(REGEX MATCH "[.]harfbuzz[ \t\r\n]*=[ \t\r\n]*[.][{][ \t\r\n]*[.]url[ \t\r\n]*=[ \t\r\n]*\"([^\"]+)\"" gui_harfbuzz_dependency "${gui_dependency_manifest}")
if(NOT gui_harfbuzz_dependency)
  message(FATAL_ERROR "The HarfBuzz dependency is missing from build.zig.zon")
endif()

FetchContent_Declare(telar_harfbuzz
  URL "${CMAKE_MATCH_1}"
  URL_HASH SHA256=f16351bafe214725fe2c1d5b59f0d93e49905a4b247899fb90d70cff953a2b9b
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR telar-source-only)
FetchContent_MakeAvailable(telar_harfbuzz)

add_library(gui-harfbuzz STATIC "${telar_harfbuzz_SOURCE_DIR}/src/harfbuzz.cc")
find_package(Threads REQUIRED)
target_include_directories(gui-harfbuzz SYSTEM PUBLIC "${telar_harfbuzz_SOURCE_DIR}/src")
target_link_libraries(gui-harfbuzz PUBLIC gui-freetype Threads::Threads)
target_compile_definitions(gui-harfbuzz PRIVATE
  HAVE_STDBOOL_H HAVE_UNISTD_H HAVE_SYS_MMAN_H HAVE_PTHREAD=1 HAVE_FREETYPE=1
  HAVE_FT_GET_VAR_BLEND_COORDINATES=1 HAVE_FT_SET_VAR_BLEND_COORDINATES=1
  HAVE_FT_DONE_MM_VAR=1 HAVE_FT_GET_TRANSFORM=1)
set_target_properties(gui-harfbuzz PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(gui-harfbuzz INTERFACE "LINKER:--exclude-libs,$<TARGET_FILE_NAME:gui-harfbuzz>")
endif()
if(TELAR_GUI_SANITIZERS)
  target_compile_options(gui-harfbuzz PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
endif()

install(FILES "${telar_harfbuzz_SOURCE_DIR}/COPYING" DESTINATION share/licenses/telar-gui RENAME harfbuzz.txt)
