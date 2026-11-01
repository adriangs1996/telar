include(FetchContent)

set(BUILD_GMOCK OFF CACHE BOOL "Build Google Mock" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Install GoogleTest" FORCE)
if(MSVC)
  set(gtest_force_shared_crt ON CACHE BOOL "Use the shared MSVC runtime" FORCE)
endif()

# Match the GoogleTest version used by the other dlls projects.
FetchContent_Declare(googletest
  URL https://codeload.github.com/google/googletest/tar.gz/063de7e9578f82b369302001269680b4b1553359
  URL_HASH SHA256=623fe05d283020f37a579a8985ba338091ac7229da62b5591ff40acdf05b95e2
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SYSTEM)
FetchContent_MakeAvailable(googletest)

file(GLOB_RECURSE tbc_test_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tests/*_test.cpp")
add_executable(tbc-tests ${tbc_test_sources})
target_link_libraries(tbc-tests PRIVATE tbc::tbc tbc_options GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(tbc-tests DISCOVERY_MODE PRE_TEST DISCOVERY_TIMEOUT 30 PROPERTIES TIMEOUT 30)
if(TBC_BUILD_EXAMPLE)
  add_test(NAME tbc-example COMMAND tbc-example)
  set_tests_properties(tbc-example PROPERTIES TIMEOUT 30)
endif()

if(TBC_BUILD_LINTER)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_test(NAME tbc-lint-contract
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/linter_test.py"
      "$<TARGET_FILE:tbc-lint>" "${CMAKE_CURRENT_SOURCE_DIR}/include" "${CMAKE_OSX_SYSROOT}" "${tbc_clang}")
  set_tests_properties(tbc-lint-contract PROPERTIES TIMEOUT 60)

  add_test(NAME tbc-spec-runner COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/spec_runner_test.py")
  set_tests_properties(tbc-spec-runner PROPERTIES TIMEOUT 30 LABELS "spec")

  set(tbc_spec_command "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/spec_runner.py"
    "--compiler=${CMAKE_CXX_COMPILER}" "--linter=$<TARGET_FILE:tbc-lint>" "--sysroot=${CMAKE_OSX_SYSROOT}")
  foreach(mode IN ITEMS validate implemented)
    add_test(NAME tbc-spec-${mode} COMMAND ${tbc_spec_command} "--mode=${mode}")
    set_tests_properties(tbc-spec-${mode} PROPERTIES TIMEOUT 180 LABELS "spec")
  endforeach()
  add_custom_target(spec-check
    COMMAND ${tbc_spec_command} --mode=all
    DEPENDS tbc-lint
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    VERBATIM)
endif()
