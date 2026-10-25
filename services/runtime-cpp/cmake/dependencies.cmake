set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
find_library(GHOSTTY_VT_LIBRARY NAMES libghostty-vt.a HINTS "${GHOSTTY_VT_ROOT}/lib" REQUIRED)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_library(SQLITE3_LIBRARY NAMES sqlite3 REQUIRED)
find_package(Threads REQUIRED)

option(TELAR_RUNTIME_DISTRIBUTABLE "Require static non-system dependencies for installation" OFF)
if(TELAR_RUNTIME_DISTRIBUTABLE)
  set(OPENSSL_USE_STATIC_LIBS TRUE)
endif()
find_package(OpenSSL 3.0...<4.0 REQUIRED)

set(NGHTTP2_ROOT "" CACHE PATH "Installed nghttp2 prefix")
find_path(NGHTTP2_INCLUDE_DIR nghttp2/nghttp2.h HINTS "${NGHTTP2_ROOT}/include" REQUIRED)
find_library(NGHTTP2_LIBRARY NAMES libnghttp2.a nghttp2 HINTS "${NGHTTP2_ROOT}/lib" REQUIRED)

find_library(ZLIB_LIBRARY NAMES z REQUIRED)

set(BROTLI_ROOT "" CACHE PATH "Installed Brotli prefix")
find_path(BROTLI_INCLUDE_DIR brotli/decode.h HINTS "${BROTLI_ROOT}/include" REQUIRED)
find_library(BROTLI_DECODER_LIBRARY NAMES libbrotlidec.a brotlidec HINTS "${BROTLI_ROOT}/lib" REQUIRED)
find_library(BROTLI_COMMON_LIBRARY NAMES libbrotlicommon.a brotlicommon HINTS "${BROTLI_ROOT}/lib" REQUIRED)

set(ZSTD_ROOT "" CACHE PATH "Installed Zstd prefix")
find_path(ZSTD_INCLUDE_DIR zstd.h HINTS "${ZSTD_ROOT}/include" REQUIRED)
find_library(ZSTD_LIBRARY NAMES libzstd.a HINTS "${ZSTD_ROOT}/lib" REQUIRED)

set(PNG_ROOT "" CACHE PATH "Installed libpng prefix")
if(TELAR_RUNTIME_DISTRIBUTABLE)
  find_library(PNG_LIBRARY NAMES libpng16.a libpng.a HINTS "${PNG_ROOT}/lib" REQUIRED)
else()
  find_library(PNG_LIBRARY NAMES png16 png HINTS "${PNG_ROOT}/lib" REQUIRED)
endif()
find_path(PNG_INCLUDE_DIR NAMES png.h HINTS "${PNG_ROOT}/include" PATH_SUFFIXES libpng16 REQUIRED)

if(TELAR_RUNTIME_DISTRIBUTABLE)
  foreach(dependency IN ITEMS GHOSTTY_VT_LIBRARY NGHTTP2_LIBRARY BROTLI_DECODER_LIBRARY BROTLI_COMMON_LIBRARY ZSTD_LIBRARY PNG_LIBRARY OPENSSL_SSL_LIBRARY OPENSSL_CRYPTO_LIBRARY)
    if(NOT "${${dependency}}" MATCHES "\\.a$")
      message(FATAL_ERROR "${dependency} must be static for distribution; configure a fresh build directory with a static library prefix")
    endif()
  endforeach()
endif()
