telar_add_library(telar-remote
  SOURCES identity/identity.cpp channel/channel.cpp streams/streams.cpp serve/serve.cpp link/link.cpp
  DEPS telar::tls telar::platform)

if(BUILD_TESTING)
  telar_add_tests(telar-remote-tests LABEL lib.remote LINK telar::remote telar::tls telar::platform telar::base)
endif()
