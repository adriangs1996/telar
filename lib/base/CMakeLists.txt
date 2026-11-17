# The lifetime annotations its interfaces declare come from telar.tbc, and the socket
# addresses text.cpp parses from telar.sys.
telar_add_library(telar-base
  SOURCES diagnostics/diagnostics.cpp editors/editors.cpp history/history.cpp text/text.cpp text/json/json.cpp memory/containers/containers.cpp memory/sensitive/sensitive.cpp
  INCLUDES "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>" "$<INSTALL_INTERFACE:include>"
  DEPS telar::tbc telar::sys)
# A ThinLTO archive holds bitcode, which a linker reads only through the compiler's LTO: ld64
# does, GNU ld does not, so an ELF consumer of the installed package links with the
# toolchain's lld, as this tree does (cmake/TelarBuild.cmake).
if(TELAR_THIN_LTO AND NOT APPLE)
  target_link_options(telar-base INTERFACE "$<INSTALL_INTERFACE:$<$<CONFIG:Release,RelWithDebInfo>:-fuse-ld=lld>>")
endif()

if(BUILD_TESTING)
  telar_add_tests(telar-base-tests LABEL lib.base LINK telar::base)
  target_compile_definitions(telar-base-tests PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
  target_compile_options(telar-base-tests PRIVATE ${TELAR_WARNINGS})

  # Compile residual ABI/macro headers and every import independently, without client or runtime paths.
  add_library(telar-base-headers OBJECT)
  target_link_libraries(telar-base-headers PRIVATE telar::base)
  target_compile_definitions(telar-base-headers PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
  file(GLOB_RECURSE base_headers RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/include" CONFIGURE_DEPENDS "include/*.hpp")
  foreach(header IN LISTS base_headers)
    set(probe "${CMAKE_CURRENT_BINARY_DIR}/headers/${header}.cpp")
    file(GENERATE OUTPUT "${probe}" CONTENT "#include <${header}>\n")
    target_sources(telar-base-headers PRIVATE "${probe}")
  endforeach()
  add_library(telar-base-imports OBJECT)
  target_link_libraries(telar-base-imports PRIVATE telar::base)
  file(GLOB_RECURSE base_interfaces CONFIGURE_DEPENDS "*.cppm")
  list(FILTER base_interfaces EXCLUDE REGEX "/(tests|out(-[^/]*)?|CMakeFiles)/")
  foreach(interface IN LISTS base_interfaces)
    file(STRINGS "${interface}" declaration REGEX "^export module ")
    string(REGEX MATCH "^export module ([A-Za-z0-9_.]+)" module_match "${declaration}")
    set(module_name "${CMAKE_MATCH_1}")
    set(probe "${CMAKE_CURRENT_BINARY_DIR}/imports/${module_name}.cpp")
    file(GENERATE OUTPUT "${probe}" CONTENT "import ${module_name};\n")
    target_sources(telar-base-imports PRIVATE "${probe}")
  endforeach()
  add_dependencies(telar-base-tests telar-base-headers telar-base-imports)

  # Probes run by hand by tools/bench_memory_call.py, never by CTest. `base-probes` builds them.
  # The -single probe links one implementation of Memory, the other several.
  foreach(probe IN ITEMS memory-call-probe memory-call-probe-single)
    add_executable(${probe} tests/memory_call_probe.cpp tests/memory_call_source.cpp)
    target_link_libraries(${probe} PRIVATE telar::base)
    target_compile_options(${probe} PRIVATE ${TELAR_WARNINGS})
  endforeach()
  target_compile_definitions(memory-call-probe PRIVATE MEMORY_CALL_IMPLEMENTATIONS=3)
  target_compile_definitions(memory-call-probe-single PRIVATE MEMORY_CALL_IMPLEMENTATIONS=1)
  set_target_properties(memory-call-probe memory-call-probe-single PROPERTIES EXCLUDE_FROM_ALL ON)
  add_custom_target(base-probes DEPENDS memory-call-probe memory-call-probe-single)
endif()

include(CMakePackageConfigHelpers)
set(telar_base_package_directory "lib/cmake/telar-base")
set_target_properties(telar-base PROPERTIES EXPORT_NAME base)
# The package carries the telar.tbc module its interfaces import, under the same telar::tbc name.
set_target_properties(telar-tbc PROPERTIES EXPORT_NAME tbc)
# And the telar.sys modules text.cpp reads socket addresses through, as telar::sys.
set_target_properties(telar-sys PROPERTIES EXPORT_NAME sys)
# The modules carry the build-wide variants they were compiled with, as telar::build_flags.
configure_package_config_file(cmake/telar-base-config.cmake.in
  "${CMAKE_CURRENT_BINARY_DIR}/telar-base-config.cmake"
  INSTALL_DESTINATION "${telar_base_package_directory}")
install(TARGETS telar-base telar-tbc telar-sys telar-build-flags EXPORT telar-base-targets
  ARCHIVE DESTINATION lib
  FILE_SET CXX_MODULES DESTINATION share/telar-base/modules)
install(DIRECTORY include/ DESTINATION include FILES_MATCHING PATTERN "*.hpp" PATTERN "*.h")
install(EXPORT telar-base-targets NAMESPACE telar:: CXX_MODULES_DIRECTORY modules DESTINATION "${telar_base_package_directory}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/telar-base-config.cmake" DESTINATION "${telar_base_package_directory}")
