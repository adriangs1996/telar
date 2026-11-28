cmake_minimum_required(VERSION 3.25)

if(CMAKE_HOST_APPLE AND (NOT CMAKE_SYSTEM_NAME OR CMAKE_SYSTEM_NAME STREQUAL "Darwin"))
  if(NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
      OUTPUT_VARIABLE qt_moc_macos_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_OSX_SYSROOT "${qt_moc_macos_sdk}" CACHE PATH "macOS SDK")
  endif()
endif()

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(CMAKE_CXX_FLAGS "-stdlib=libstdc++" CACHE STRING "LLVM development SDK C++ ABI")
  set(CMAKE_CXX_STANDARD_LIBRARIES "-lstdc++" CACHE STRING "LLVM development SDK C++ runtime")
endif()

project(telar_qt_moc VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

get_filename_component(qt_moc_compiler "${CMAKE_CXX_COMPILER}" REALPATH)
get_filename_component(qt_moc_bin "${qt_moc_compiler}" DIRECTORY)
get_filename_component(qt_moc_llvm "${qt_moc_bin}/.." ABSOLUTE)
find_package(LLVM CONFIG REQUIRED HINTS "${qt_moc_llvm}/lib/cmake/llvm")
find_package(Clang CONFIG REQUIRED HINTS "${LLVM_DIR}/../clang")

find_program(qt_moc_clang NAMES clang HINTS "${LLVM_TOOLS_BINARY_DIR}" NO_DEFAULT_PATH REQUIRED)
execute_process(COMMAND "${qt_moc_clang}" -print-resource-dir
  OUTPUT_VARIABLE qt_moc_clang_resources OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)

separate_arguments(qt_moc_llvm_definitions NATIVE_COMMAND "${LLVM_DEFINITIONS}")

add_library(qt_moc_options INTERFACE)
target_compile_options(qt_moc_options INTERFACE -Wall -Wextra -Wpedantic)
target_include_directories(qt_moc_options SYSTEM INTERFACE ${LLVM_INCLUDE_DIRS} ${CLANG_INCLUDE_DIRS})
target_compile_options(qt_moc_options INTERFACE ${qt_moc_llvm_definitions})
if(NOT LLVM_ENABLE_RTTI)
  target_compile_options(qt_moc_options INTERFACE -fno-rtti)
endif()

add_library(telar-qt-plugin MODULE
  src/attributes.cpp
  src/plugin.cpp)
set_target_properties(telar-qt-plugin PROPERTIES PREFIX "" SUFFIX ".so" POSITION_INDEPENDENT_CODE ON)
target_link_libraries(telar-qt-plugin PRIVATE qt_moc_options)
if(APPLE)
  target_link_options(telar-qt-plugin PRIVATE -undefined dynamic_lookup)
endif()

add_executable(telar-moc
  src/attributes.cpp
  src/ast_extractor.cpp
  src/emit_moc.cpp
  src/emit_json.cpp
  src/emit_qmlreg.cpp
  src/main.cpp)
target_compile_definitions(telar-moc PRIVATE "TELAR_QT_MOC_RESOURCE_DIR=\"${qt_moc_clang_resources}\"")
target_link_libraries(telar-moc PRIVATE qt_moc_options clang-cpp)
if(TARGET LLVM)
  target_link_libraries(telar-moc PRIVATE LLVM)
endif()
