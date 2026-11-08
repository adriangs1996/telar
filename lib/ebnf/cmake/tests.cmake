include(FetchContent)

set(BUILD_GMOCK OFF CACHE BOOL "Build Google Mock" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Install GoogleTest" FORCE)
if(MSVC)
  set(gtest_force_shared_crt ON CACHE BOOL "Use the shared MSVC runtime" FORCE)
endif()

# GoogleTest v1.18.0, pinned by commit and archive checksum.
FetchContent_Declare(googletest
  URL https://codeload.github.com/google/googletest/tar.gz/063de7e9578f82b369302001269680b4b1553359
  URL_HASH SHA256=623fe05d283020f37a579a8985ba338091ac7229da62b5591ff40acdf05b95e2
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  SYSTEM)
FetchContent_MakeAvailable(googletest)

add_executable(ebnf_tests ${ebnf_test_sources} ${ebnf_sources})
target_link_libraries(ebnf_tests PRIVATE ebnf_options GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(ebnf_tests
  DISCOVERY_MODE PRE_TEST
  DISCOVERY_TIMEOUT 30
  PROPERTIES TIMEOUT 30)
