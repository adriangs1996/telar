# Resolve the development SDK beside the selected compiler, including presets.
get_filename_component(tbc_compiler "${CMAKE_CXX_COMPILER}" REALPATH)
get_filename_component(tbc_bin "${tbc_compiler}" DIRECTORY)
get_filename_component(tbc_llvm "${tbc_bin}/.." ABSOLUTE)
find_package(LLVM CONFIG REQUIRED HINTS "${tbc_llvm}/lib/cmake/llvm")
find_package(Clang CONFIG REQUIRED HINTS "${LLVM_DIR}/../clang")

if(LLVM_VERSION_MAJOR LESS 18)
  message(FATAL_ERROR "tbc-lint requires LLVM/Clang 18 or newer")
endif()

find_program(tbc_clang NAMES clang HINTS "${LLVM_TOOLS_BINARY_DIR}" NO_DEFAULT_PATH REQUIRED)
execute_process(COMMAND "${tbc_clang}" -print-resource-dir
  OUTPUT_VARIABLE tbc_clang_resources OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)

add_executable(tbc-lint linter/main.cpp linter/lifetime_analysis.cpp)
target_include_directories(tbc-lint SYSTEM PRIVATE ${LLVM_INCLUDE_DIRS} ${CLANG_INCLUDE_DIRS})
separate_arguments(tbc_llvm_definitions NATIVE_COMMAND "${LLVM_DEFINITIONS}")
target_compile_options(tbc-lint PRIVATE ${tbc_llvm_definitions})
target_compile_definitions(tbc-lint PRIVATE "TBC_CLANG_RESOURCE_DIR=\"${tbc_clang_resources}\"")
target_link_libraries(tbc-lint PRIVATE tbc_options clang-cpp)
# Official LLVM distributions may embed LLVM in clang-cpp instead of shipping
# the separate monolithic LLVM shared library used by distro development SDKs.
if(TARGET LLVM)
  target_link_libraries(tbc-lint PRIVATE LLVM)
endif()

if(NOT LLVM_ENABLE_RTTI)
  if(MSVC)
    target_compile_options(tbc-lint PRIVATE /GR-)
  else()
    target_compile_options(tbc-lint PRIVATE -fno-rtti)
  endif()
endif()
