include_guard(GLOBAL)

# The runtime's other native libraries as deps::<name>. nghttp2, Brotli and
# zstd are pinned and built static once into TELAR_DEPENDENCIES_DIR; zlib,
# SQLite and libpcap are built with them on Linux and taken from the SDK on
# macOS, whose copies Apple patches with the OS, never a package manager's.
# The targets only link: telar::native (lib/native) owns the headers under
# TELAR_NATIVE_INCLUDE_DIR.
cmake_path(GET CMAKE_CURRENT_LIST_DIR PARENT_PATH telar_cmake_directory)
include("${telar_cmake_directory}/dependencies.cmake")

telar_managed_build(NAME "native libraries" RECIPE "${telar_cmake_directory}/native"
  ROOT "${TELAR_DEPENDENCIES_DIR}/native" TARGET telar-native JOBS "${TELAR_DEPENDENCIES_JOBS}"
  FILES CMakeLists.txt manifest.cmake sqlite.cmake RESULT TELAR_NATIVE_PREFIX)
set(TELAR_NATIVE_INCLUDE_DIR "${TELAR_NATIVE_PREFIX}/include")

# Earlier configurations searched the system for these; the managed build
# and the SDK supply them now.
foreach(variable IN ITEMS NGHTTP2_ROOT NGHTTP2_INCLUDE_DIR NGHTTP2_LIBRARY BROTLI_ROOT BROTLI_INCLUDE_DIR
    BROTLI_DECODER_LIBRARY BROTLI_ENCODER_LIBRARY BROTLI_COMMON_LIBRARY ZSTD_ROOT ZSTD_INCLUDE_DIR ZSTD_LIBRARY
    ZLIB_LIBRARY SQLITE3_LIBRARY PCAP_LIBRARY)
  unset(${variable} CACHE)
endforeach()

# deps::<name> links the library at location.
function(telar_import_native name location)
  add_library(deps::${name} UNKNOWN IMPORTED GLOBAL)
  set_target_properties(deps::${name} PROPERTIES IMPORTED_LOCATION "${location}")
endfunction()

# Each entry is <name>=<file>, the library's file name without lib and extension.
set(telar_native_managed nghttp2=nghttp2 brotli_decoder=brotlidec brotli_encoder=brotlienc
  brotli_common=brotlicommon zstd=zstd)
set(telar_native_platform zlib=z sqlite3=sqlite3 pcap=pcap)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND telar_native_managed ${telar_native_platform})
  set(telar_native_platform)
endif()

foreach(entry IN LISTS telar_native_managed)
  string(REPLACE "=" ";" entry "${entry}")
  list(GET entry 0 name)
  list(GET entry 1 file)
  set(location "${TELAR_NATIVE_PREFIX}/lib/lib${file}.a")
  if(NOT EXISTS "${location}")
    message(FATAL_ERROR "The managed native build did not install ${location}")
  endif()

  telar_import_native(${name} "${location}")
endforeach()

if(telar_native_platform)
  set(telar_sdk "${CMAKE_OSX_SYSROOT}")
  if(NOT IS_ABSOLUTE "${telar_sdk}")
    if(NOT telar_sdk)
      set(telar_sdk macosx)
    endif()

    execute_process(COMMAND xcrun --sdk "${telar_sdk}" --show-sdk-path
      OUTPUT_VARIABLE telar_sdk OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
  endif()
endif()

foreach(entry IN LISTS telar_native_platform)
  string(REPLACE "=" ";" entry "${entry}")
  list(GET entry 0 name)
  list(GET entry 1 file)
  string(TOUPPER "${name}_LIBRARY" variable)
  find_library(${variable} NAMES ${file} PATHS "${telar_sdk}/usr/lib" NO_DEFAULT_PATH REQUIRED)
  telar_import_native(${name} "${${variable}}")
endforeach()
