# Editor support for the C++ projects under dlls/ and services/.
#
# A dll configured on its own (`cmake -S dlls/NAME -B dlls/NAME/out`) has no
# translation units of its own for clangd to borrow flags from, so
# telar_editor_flags writes out/clangd/compile_flags.txt with the include
# directories and definitions its consumers compile its headers with,
# dependencies included. The dll's .clangd points clangd there.

# Standalone LLVM tools need the SDK named on macOS. Include before project().
if(CMAKE_HOST_APPLE AND NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE telar_editor_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
  set(CMAKE_OSX_SYSROOT "${telar_editor_sdk}" CACHE PATH "macOS SDK")
endif()

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# telar_editor_flags(TARGET [GHOSTTY]): GHOSTTY adds libghostty-vt's headers,
# which telar-config's headers include but leave to their consumers to link.
function(telar_editor_flags target)
  if(NOT PROJECT_IS_TOP_LEVEL)
    return()
  endif()

  cmake_parse_arguments(PARSE_ARGV 1 editor "GHOSTTY" "" "")
  set(directory "${CMAKE_BINARY_DIR}/clangd")
  file(CONFIGURE OUTPUT "${directory}/probe.cpp" CONTENT "")
  add_library(${target}-editor OBJECT EXCLUDE_FROM_ALL "${directory}/probe.cpp")
  target_link_libraries(${target}-editor PRIVATE ${target})
  target_compile_features(${target}-editor PRIVATE cxx_std_23)
  if(editor_GHOSTTY)
    set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
    find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt/unicode.h HINTS "${GHOSTTY_VT_ROOT}/include")
    if(GHOSTTY_VT_INCLUDE_DIR)
      target_include_directories(${target}-editor PRIVATE "${GHOSTTY_VT_INCLUDE_DIR}")
    else()
      message(WARNING "libghostty-vt headers not found; pass -DGHOSTTY_VT_ROOT (just vt installs them)")
    endif()
  endif()

  set(sysroot "")
  if(CMAKE_OSX_SYSROOT)
    set(sysroot "-isysroot\n${CMAKE_OSX_SYSROOT}\n")
  endif()

  set(includes "$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${target}-editor,INCLUDE_DIRECTORIES>>")
  set(definitions "$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${target}-editor,COMPILE_DEFINITIONS>>")
  file(GENERATE OUTPUT "${directory}/compile_flags.txt"
    CONTENT "-xc++\n-std=c++23\n${sysroot}$<$<BOOL:${includes}>:-I$<JOIN:${includes},\n-I>\n>$<$<BOOL:${definitions}>:-D$<JOIN:${definitions},\n-D>\n>")
endfunction()
