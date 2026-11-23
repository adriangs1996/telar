telar_process(gateway)

if(NOT APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The gateway supports macOS and Linux")
endif()

# telar-gateway is the one program that speaks to another machine: the gateway that
# answers clients there, and the link and the one-shot commands that call it from here.
# The runtime, the CLI and the GUI start it and never link what it links.
add_executable(telar-gateway main.cpp)
target_link_libraries(telar-gateway PRIVATE telar::remote telar::tls telar::platform telar::base telar::build_flags)
target_compile_options(telar-gateway PRIVATE ${TELAR_WARNINGS})
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_compile_definitions(telar-gateway PRIVATE _GNU_SOURCE)
endif()
# `telar` and the windows start the gateway installed beside them, and the gateway starts
# the `telar` beside it, so it builds into the directory of the runtime and the CLI.
if(TARGET telar-runtime)
  get_target_property(telar_runtime_directory telar-runtime BINARY_DIR)
  set_target_properties(telar-gateway PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${telar_runtime_directory}")
endif()
install(TARGETS telar-gateway RUNTIME DESTINATION bin)

telar_register_checks(telar-gateway CHECKS lint lifetime)
