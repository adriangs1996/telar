include_guard(GLOBAL)

# What the compiler targets, read before project() so every telar target and every
# managed dependency builds for the same platform. The managed builds key their
# installations on these values (cmake/managed_build.cmake).

# Standalone LLVM tools (clangd, clang-tidy, tbc-lint) need the SDK named in the
# compilation database on macOS.
if(CMAKE_HOST_APPLE AND NOT CMAKE_OSX_SYSROOT AND NOT DEFINED ENV{SDKROOT})
  execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
    OUTPUT_VARIABLE telar_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
  set(CMAKE_OSX_SYSROOT "${telar_sdk}" CACHE PATH "macOS SDK" FORCE)
endif()

# The oldest macOS every process and dependency runs on.
if(CMAKE_HOST_APPLE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum supported macOS version")
endif()
