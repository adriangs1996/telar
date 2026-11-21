telar_add_domain(runtime nvim
  SOURCES
    editor/editor.cpp
    frames/frames.cpp
    redraw/redraw.cpp
    rpc/rpc.cpp
    screen/screen.cpp
  DEPS telar::msgpack telar::wire)

if(BUILD_TESTING)
  telar_add_domain_tests(nvim LINK telar::base telar::msgpack telar::wire)
endif()
