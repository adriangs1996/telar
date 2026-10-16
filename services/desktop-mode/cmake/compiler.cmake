# Keep all module producers and consumers on the same compiler and libstdc++.
if(NOT CMAKE_CXX_COMPILER AND NOT DEFINED ENV{CXX})
  if(CMAKE_HOST_APPLE)
    find_program(telar_brew brew REQUIRED)
    execute_process(COMMAND "${telar_brew}" --prefix llvm
      OUTPUT_VARIABLE llvm_prefix OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_CXX_COMPILER "${llvm_prefix}/bin/clang++" CACHE FILEPATH "LLVM Clang C++ compiler")
  else()
    find_program(CMAKE_CXX_COMPILER NAMES clang++ REQUIRED)
  endif()
endif()

set(GCC_CXX "$ENV{GXX}" CACHE FILEPATH "GCC driver providing C++23 libstdc++")
if(NOT GCC_CXX)
  find_program(telar_gcc NAMES g++-16 g++-15 g++-14 g++ REQUIRED)
  set(GCC_CXX "${telar_gcc}" CACHE FILEPATH "GCC driver providing C++23 libstdc++" FORCE)
endif()

execute_process(COMMAND "${GCC_CXX}" -E -x c++ -v -
  INPUT_FILE /dev/null OUTPUT_QUIET ERROR_VARIABLE gcc_includes
  COMMAND_ERROR_IS_FATAL ANY)
string(REPLACE "\n" ";" gcc_include_lines "${gcc_includes}")
set(telar_cxx_flags "-stdlib=libstdc++ -nostdinc++")
set(telar_found_headers FALSE)
foreach(line IN LISTS gcc_include_lines)
  if(line MATCHES "^ +([^ ].*/c\\+\\+/.*)$")
    string(STRIP "${CMAKE_MATCH_1}" include_dir)
    string(APPEND telar_cxx_flags " -isystem \"${include_dir}\"")
    set(telar_found_headers TRUE)
  endif()
endforeach()
if(NOT telar_found_headers)
  message(FATAL_ERROR "GCC did not report libstdc++ headers; set GXX or GCC_CXX to a GNU GCC driver")
endif()

if(CMAKE_HOST_APPLE)
  set(telar_stdlib_name libstdc++.dylib)
else()
  set(telar_stdlib_name libstdc++.so)
endif()
execute_process(COMMAND "${GCC_CXX}" "-print-file-name=${telar_stdlib_name}"
  OUTPUT_VARIABLE telar_stdlib OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY)
if(NOT IS_ABSOLUTE "${telar_stdlib}" OR NOT EXISTS "${telar_stdlib}")
  message(FATAL_ERROR "GCC did not report a usable libstdc++ library; set GXX or GCC_CXX")
endif()
get_filename_component(telar_stdlib_dir "${telar_stdlib}" DIRECTORY)
string(APPEND CMAKE_CXX_FLAGS_INIT " ${telar_cxx_flags}")
string(APPEND CMAKE_OBJCXX_FLAGS_INIT " ${telar_cxx_flags}")
string(APPEND CMAKE_EXE_LINKER_FLAGS_INIT " -L\"${telar_stdlib_dir}\" -Wl,-rpath,\"${telar_stdlib_dir}\"")
