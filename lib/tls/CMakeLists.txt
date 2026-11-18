include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/openssl.cmake")

telar_add_library(telar-tls
  SOURCES tls.cpp
  DEPS telar::platform OpenSSL::SSL OpenSSL::Crypto)

if(BUILD_TESTING)
  telar_add_tests(telar-tls-tests LABEL lib.tls LINK telar::tls telar::platform telar::base)
endif()
