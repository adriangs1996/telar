telar_add_library(telar-msgpack
  SOURCES msgpack.cpp
  DEPS telar::base)
target_compile_options(telar-msgpack PRIVATE ${TELAR_WARNINGS})

if(BUILD_TESTING)
  telar_add_tests(telar-msgpack-tests LABEL lib.msgpack LINK telar::msgpack)
  target_compile_options(telar-msgpack-tests PRIVATE ${TELAR_WARNINGS})
endif()
