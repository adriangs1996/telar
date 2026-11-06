cmake_minimum_required(VERSION 3.25)
include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/telar_editor.cmake")
project(websock LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TARGET telar-base)
  add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../telar-base" "${CMAKE_CURRENT_BINARY_DIR}/telar-base")
endif()

add_library(websock INTERFACE)
add_library(telar::websock ALIAS websock)
target_compile_features(websock INTERFACE cxx_std_23)
target_link_libraries(websock INTERFACE telar::base)
target_include_directories(websock INTERFACE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/includes>"
  "$<INSTALL_INTERFACE:include>")

telar_editor_flags(websock)

# Development settings must not propagate to the server or client consuming the library.
if(PROJECT_IS_TOP_LEVEL)
  option(WEBSOCK_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" OFF)
  option(WEBSOCK_SANITIZERS "Enable address and undefined behavior sanitizers" OFF)
  include(CTest)
  if(BUILD_TESTING)
    add_executable(websock-smoke main.cpp)
    target_link_libraries(websock-smoke PRIVATE telar::websock)
    target_compile_options(websock-smoke PRIVATE -Wall -Wextra -Wpedantic)
    if(WEBSOCK_WARNINGS_AS_ERRORS)
      target_compile_options(websock-smoke PRIVATE -Werror)
    endif()
    if(WEBSOCK_SANITIZERS)
      if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        message(FATAL_ERROR "WEBSOCK_SANITIZERS requires GCC or Clang")
      endif()
      target_compile_options(websock-smoke PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
      target_link_options(websock-smoke PRIVATE -fsanitize=address,undefined)
    endif()
    add_test(NAME websock-smoke COMMAND websock-smoke)
    set_tests_properties(websock-smoke PROPERTIES TIMEOUT 10)
  endif()

  get_filename_component(websock_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
  foreach(mode IN ITEMS format format-check lint)
    add_custom_target(${mode}
      COMMAND "${CMAKE_COMMAND}"
        "-DMODE=${mode}"
        "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
        "-DBINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}"
        "-DCOMPILER_DIR=${websock_compiler_directory}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/../tbc/cmake/tooling.cmake"
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      USES_TERMINAL
      VERBATIM)
  endforeach()
endif()

include(CMakePackageConfigHelpers)
set(websock_package_directory "lib/cmake/websock")
configure_package_config_file(cmake/websock-config.cmake.in
  "${CMAKE_CURRENT_BINARY_DIR}/websock-config.cmake"
  INSTALL_DESTINATION "${websock_package_directory}")
install(TARGETS websock EXPORT websock-targets)
install(DIRECTORY includes/ DESTINATION include)
install(EXPORT websock-targets NAMESPACE telar:: DESTINATION "${websock_package_directory}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/websock-config.cmake" DESTINATION "${websock_package_directory}")
