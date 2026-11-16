include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

telar_add_library(telar-tls
  SOURCES tls.cpp
  INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/include"
  DEPS telar::platform OpenSSL::SSL OpenSSL::Crypto)
