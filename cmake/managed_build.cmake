include_guard(GLOBAL)

# Builds a pinned third-party dependency once from its recipe directory, a
# CMake project whose TARGET downloads, verifies, builds and installs it into
# <build>/install. Builds are keyed by the compiler, the flags that reach the
# dependency, managed_toolchain.cmake and the recipe's FILES, so a changed pin
# or toolchain gets a new directory instead of reusing an old installation. A
# completed key is reused as it is, from any checkout sharing the cache.
#
# telar_managed_build(NAME label RECIPE dir ROOT cache TARGET target JOBS n
#                     FILES file... RESULT variable)
function(telar_managed_build)
  cmake_parse_arguments(PARSE_ARGV 0 managed "" "NAME;RECIPE;ROOT;TARGET;JOBS;RESULT" "FILES")
  if(NOT managed_JOBS MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "Parallel jobs for ${managed_NAME} must be a positive integer")
  endif()

  if(CMAKE_CROSSCOMPILING)
    message(FATAL_ERROR "Managed dependency builds support native builds only")
  endif()

  find_program(TELAR_MANAGED_NINJA ninja REQUIRED)
  set(arguments "-DCMAKE_MAKE_PROGRAM:FILEPATH=${TELAR_MANAGED_NINJA}")
  set(identity "${CMAKE_SYSTEM_NAME};${CMAKE_SYSTEM_PROCESSOR};${CMAKE_C_COMPILER_ID};${CMAKE_C_COMPILER_VERSION};${CMAKE_CXX_COMPILER_ID};${CMAKE_CXX_COMPILER_VERSION}")
  foreach(variable IN ITEMS
      CMAKE_C_COMPILER CMAKE_CXX_COMPILER
      CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER
      CMAKE_OSX_ARCHITECTURES CMAKE_OSX_DEPLOYMENT_TARGET CMAKE_OSX_SYSROOT
      CMAKE_TOOLCHAIN_FILE CMAKE_SYSROOT CMAKE_C_FLAGS CMAKE_CXX_FLAGS
      CMAKE_C_FLAGS_RELEASE CMAKE_CXX_FLAGS_RELEASE)
    if(DEFINED ${variable} AND NOT "${${variable}}" STREQUAL "")
      string(REPLACE ";" "\\;" value "${${variable}}")
      list(APPEND arguments "-D${variable}:STRING=${value}")
      string(APPEND identity ";${variable}=${${variable}}")
    endif()
  endforeach()

  # A changed pin or recipe reconfigures the project that uses it, which
  # builds the new key.
  foreach(file IN LISTS managed_FILES)
    file(SHA256 "${managed_RECIPE}/${file}" digest)
    string(APPEND identity ";${file}=${digest}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${managed_RECIPE}/${file}")
  endforeach()

  set(toolchain "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/managed_toolchain.cmake")
  file(SHA256 "${toolchain}" digest)
  string(APPEND identity ";managed_toolchain.cmake=${digest}")

  if(CMAKE_TOOLCHAIN_FILE)
    file(SHA256 "${CMAKE_TOOLCHAIN_FILE}" digest)
    string(APPEND identity ";toolchain=${digest}")
  endif()

  string(SHA256 key "${identity}")
  file(MAKE_DIRECTORY "${managed_ROOT}")
  file(REAL_PATH "${managed_ROOT}" root)
  set(build "${root}/${key}")

  # Debug, Release and sanitizer builds share one installation. Serialize
  # writers so concurrent configurations cannot race installation or downloads.
  file(LOCK "${root}/bootstrap.lock" GUARD FUNCTION TIMEOUT 0 RESULT_VARIABLE lock_result)
  if(NOT lock_result STREQUAL "0")
    message(STATUS "Waiting for another ${managed_NAME} build to finish: ${root}")
    file(LOCK "${root}/bootstrap.lock" GUARD FUNCTION)
  endif()

  message(STATUS "Preparing managed ${managed_NAME}: ${build}/install")
  set(complete "${build}/complete")
  if(NOT EXISTS "${complete}")
    # An unfinished build started from another checkout names that checkout's
    # recipe; regenerate its tree here and let ExternalProject resume.
    if(EXISTS "${build}/CMakeCache.txt")
      file(STRINGS "${build}/CMakeCache.txt" home REGEX "^CMAKE_HOME_DIRECTORY:INTERNAL=")
      string(REPLACE "CMAKE_HOME_DIRECTORY:INTERNAL=" "" home "${home}")
      file(REAL_PATH "${home}" home)
      file(REAL_PATH "${managed_RECIPE}" recipe)
      if(NOT home STREQUAL recipe)
        file(REMOVE_RECURSE "${build}/CMakeCache.txt" "${build}/CMakeFiles")
      endif()
    endif()

    execute_process(COMMAND "${CMAKE_COMMAND}" -S "${managed_RECIPE}" -B "${build}" -G Ninja
        "-DTELAR_DOWNLOAD_DIR:PATH=${root}/downloads" "-DTELAR_MANAGED_JOBS:STRING=${managed_JOBS}"
        "-DTELAR_MANAGED_TOOLCHAIN:FILEPATH=${toolchain}" ${arguments}
      COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND "${CMAKE_COMMAND}" -E env "CMAKE_BUILD_PARALLEL_LEVEL=${managed_JOBS}"
        "${CMAKE_COMMAND}" --build "${build}" --target "${managed_TARGET}" --parallel 1
      COMMAND_ERROR_IS_FATAL ANY)
    file(TOUCH "${complete}")
  endif()

  set(${managed_RESULT} "${build}/install" PARENT_SCOPE)
endfunction()
