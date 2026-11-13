include(FetchContent)

# Upstream archives; each hash pins the exact contents.
FetchContent_Declare(telar_freetype
  URL "https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-2.tar.gz"
  URL_HASH SHA256=427201f5d5151670d05c1f5b45bef5dda1f2e7dd971ef54f0feaaa7ffd2ab90c
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SOURCE_SUBDIR telar-source-only)
FetchContent_MakeAvailable(telar_freetype)

# The FreeType modules Telar uses, relative to the upstream archive.
set(gui_freetype_source_names
  src/autofit/autofit.c
  src/base/ftbase.c
  src/base/ftbbox.c
  src/base/ftbdf.c
  src/base/ftbitmap.c
  src/base/ftcid.c
  src/base/ftfstype.c
  src/base/ftgasp.c
  src/base/ftglyph.c
  src/base/ftgxval.c
  src/base/ftinit.c
  src/base/ftmm.c
  src/base/ftotval.c
  src/base/ftpatent.c
  src/base/ftpfr.c
  src/base/ftstroke.c
  src/base/ftsynth.c
  src/base/fttype1.c
  src/base/ftwinfnt.c
  src/bdf/bdf.c
  src/bzip2/ftbzip2.c
  src/cache/ftcache.c
  src/cff/cff.c
  src/cid/type1cid.c
  src/gzip/ftgzip.c
  src/lzw/ftlzw.c
  src/pcf/pcf.c
  src/pfr/pfr.c
  src/psaux/psaux.c
  src/pshinter/pshinter.c
  src/psnames/psnames.c
  src/raster/raster.c
  src/sdf/sdf.c
  src/sfnt/sfnt.c
  src/smooth/smooth.c
  src/svg/svg.c
  src/truetype/truetype.c
  src/type1/type1.c
  src/type42/type42.c
  src/winfonts/winfnt.c)
list(TRANSFORM gui_freetype_source_names PREPEND "${telar_freetype_SOURCE_DIR}/" OUTPUT_VARIABLE gui_freetype_sources)

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

install(FILES "${telar_freetype_SOURCE_DIR}/docs/FTL.TXT" DESTINATION share/licenses/telar-gui RENAME freetype.txt)

FetchContent_Declare(telar_harfbuzz
  URL "https://github.com/harfbuzz/harfbuzz/releases/download/11.0.0/harfbuzz-11.0.0.tar.xz"
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
