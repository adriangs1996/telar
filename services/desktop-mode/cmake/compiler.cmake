# Keep module producers and consumers on the same LLVM installation.
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

if(CMAKE_HOST_APPLE)
  if(NOT DEFINED CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
    execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
      OUTPUT_VARIABLE telar_macos_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
    set(CMAKE_OSX_SYSROOT "${telar_macos_sdk}" CACHE PATH "macOS SDK")
  endif()

  string(APPEND CMAKE_CXX_FLAGS_INIT " -stdlib=libc++")
  string(APPEND CMAKE_OBJCXX_FLAGS_INIT " -stdlib=libc++")
endif()
