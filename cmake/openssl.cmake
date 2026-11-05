include_guard(GLOBAL)

# Every C++ project links the same pinned, static OpenSSL, built once into
# TELAR_DEPENDENCIES_DIR. The system's OpenSSL is never used: its version and
# configuration would vary between machines.
include("${CMAKE_CURRENT_LIST_DIR}/dependencies.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/openssl/manifest.cmake")

telar_managed_build(NAME "OpenSSL ${TELAR_OPENSSL_VERSION}" RECIPE "${CMAKE_CURRENT_LIST_DIR}/openssl"
  ROOT "${TELAR_DEPENDENCIES_DIR}/openssl" TARGET telar-openssl JOBS "${TELAR_DEPENDENCIES_JOBS}"
  FILES CMakeLists.txt manifest.cmake immediate-cleanup.patch RESULT TELAR_OPENSSL_PREFIX)

# Forget what an earlier configuration found, which may be the system's
# OpenSSL or another managed build.
foreach(variable IN ITEMS OPENSSL_INCLUDE_DIR OPENSSL_CRYPTO_LIBRARY OPENSSL_SSL_LIBRARY OPENSSL_ROOT_DIR)
  unset(${variable} CACHE)
endforeach()

set(OPENSSL_ROOT_DIR "${TELAR_OPENSSL_PREFIX}")
set(OPENSSL_USE_STATIC_LIBS TRUE)
find_package(OpenSSL ${TELAR_OPENSSL_VERSION} EXACT REQUIRED COMPONENTS SSL Crypto)
foreach(path IN ITEMS OPENSSL_INCLUDE_DIR OPENSSL_CRYPTO_LIBRARY OPENSSL_SSL_LIBRARY)
  cmake_path(IS_PREFIX TELAR_OPENSSL_PREFIX "${${path}}" NORMALIZE managed)
  if(NOT managed)
    message(FATAL_ERROR "${path} resolved outside the managed OpenSSL installation: ${${path}}")
  endif()
endforeach()

# Lets the TLS code check at compile time that its OpenSSL headers are these.
set_property(TARGET OpenSSL::Crypto APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS "TELAR_OPENSSL_VERSION=\"${TELAR_OPENSSL_VERSION}\"")
