cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(telar_base LANGUAGES CXX)

add_library(telar-base INTERFACE)
add_library(telar::base ALIAS telar-base)
target_compile_features(telar-base INTERFACE cxx_std_23)
target_include_directories(telar-base INTERFACE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<INSTALL_INTERFACE:include>")

telar_editor_flags(telar-base)

if(PROJECT_IS_TOP_LEVEL)
  if(TARGET telar-client OR TARGET runtime-core)
    message(FATAL_ERROR "telar-base must not depend on the client or runtime")
  endif()
  include(CTest)
  if(BUILD_TESTING)
    add_executable(telar-base-tests tests/base_test.cpp)
    target_link_libraries(telar-base-tests PRIVATE telar::base)
    target_compile_definitions(telar-base-tests PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
    target_compile_options(telar-base-tests PRIVATE -Wall -Wextra -Wpedantic)
    add_test(NAME telar-base-tests COMMAND telar-base-tests)

    # Compile every public header alone, with no client or runtime include paths.
    add_library(telar-base-headers OBJECT)
    target_link_libraries(telar-base-headers PRIVATE telar::base)
    target_compile_definitions(telar-base-headers PRIVATE TELAR_DEBUG=$<CONFIG:Debug>)
    file(GLOB_RECURSE base_headers RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/include" CONFIGURE_DEPENDS "include/*.hpp")
    foreach(header IN LISTS base_headers)
      set(probe "${CMAKE_CURRENT_BINARY_DIR}/headers/${header}.cpp")
      file(GENERATE OUTPUT "${probe}" CONTENT "#include <${header}>\n")
      target_sources(telar-base-headers PRIVATE "${probe}")
    endforeach()
    add_dependencies(telar-base-tests telar-base-headers)
  endif()
endif()

include(CMakePackageConfigHelpers)
set(telar_base_package_directory "lib/cmake/telar-base")
set_target_properties(telar-base PROPERTIES EXPORT_NAME base)
configure_package_config_file(cmake/telar-base-config.cmake.in
  "${CMAKE_CURRENT_BINARY_DIR}/telar-base-config.cmake"
  INSTALL_DESTINATION "${telar_base_package_directory}")
install(TARGETS telar-base EXPORT telar-base-targets)
install(DIRECTORY include/ DESTINATION include)
install(EXPORT telar-base-targets NAMESPACE telar:: DESTINATION "${telar_base_package_directory}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/telar-base-config.cmake" DESTINATION "${telar_base_package_directory}")
