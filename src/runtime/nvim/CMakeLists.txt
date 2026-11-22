telar_add_domain(runtime nvim
  SOURCES
    editor/editor.cpp
    frames/frames.cpp
    provision/provision.cpp
    redraw/redraw.cpp
    rpc/rpc.cpp
    screen/screen.cpp
  DEPS telar::msgpack telar::platform telar::wire)

if(BUILD_TESTING)
  telar_add_domain_tests(nvim LINK telar::base telar::msgpack telar::platform telar::wire)
endif()
