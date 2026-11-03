include_guard(GLOBAL)

if(POLICY CMP0218)
  cmake_policy(SET CMP0218 NEW)
endif()
set(QT_NO_PRIVATE_MODULE_WARNING ON)

include("${CMAKE_CURRENT_LIST_DIR}/qt/manifest.cmake")

# Keep Qt's QML examples and fuzz fixtures outside this QML project's source tree.
set(TELAR_GUI_QT_BUILD_DIR "${TELAR_ROOT}/.qt-cache" CACHE PATH "Managed Qt source, build and installation cache")
set(TELAR_GUI_QT_JOBS 2 CACHE STRING "Parallel compiler jobs when building Qt")
if(NOT TELAR_GUI_QT_JOBS MATCHES "^[1-9][0-9]*$")
  message(FATAL_ERROR "TELAR_GUI_QT_JOBS must be a positive integer")
endif()
if(CMAKE_CROSSCOMPILING)
  message(FATAL_ERROR "The managed Qt bootstrap currently supports native builds only")
endif()
find_program(TELAR_GUI_QT_NINJA ninja REQUIRED)

function(telar_prepare_qt)
  set(recipe "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/qt")
  set(arguments "-DCMAKE_MAKE_PROGRAM:FILEPATH=${TELAR_GUI_QT_NINJA}")
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
  foreach(file IN ITEMS CMakeLists.txt manifest.cmake patch.cmake)
    file(SHA256 "${recipe}/${file}" digest)
    string(APPEND identity ";${file}=${digest}")
  endforeach()
  if(CMAKE_TOOLCHAIN_FILE)
    file(SHA256 "${CMAKE_TOOLCHAIN_FILE}" digest)
    string(APPEND identity ";toolchain=${digest}")
  endif()
  string(SHA256 key "${identity}")
  file(MAKE_DIRECTORY "${TELAR_GUI_QT_BUILD_DIR}")
  file(REAL_PATH "${TELAR_GUI_QT_BUILD_DIR}" root)
  file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}" source)
  cmake_path(IS_PREFIX source "${root}" NORMALIZE inside_source)
  if(inside_source)
    message(FATAL_ERROR "TELAR_GUI_QT_BUILD_DIR must be outside the GUI source tree so QML import scanning cannot inspect Qt's own fixtures")
  endif()
  set(build "${root}/${key}")

  # Debug, Release and sanitizer clients share one Release Qt. Serialize writers
  # so concurrent GUI configurations cannot race installation or archive downloads.
  file(LOCK "${root}/bootstrap.lock" GUARD FUNCTION TIMEOUT 0 RESULT_VARIABLE lock_result)
  if(NOT lock_result STREQUAL "0")
    message(STATUS "Waiting for another Qt bootstrap to finish: ${root}")
    file(LOCK "${root}/bootstrap.lock" GUARD FUNCTION)
  endif()
  message(STATUS "Preparing managed Qt ${TELAR_QT_VERSION}: ${build}/install")
  execute_process(COMMAND "${CMAKE_COMMAND}" -S "${recipe}" -B "${build}" -G Ninja
      "-DTELAR_QT_DOWNLOAD_DIR:PATH=${root}/downloads" ${arguments}
    COMMAND_ERROR_IS_FATAL ANY)
  execute_process(COMMAND "${CMAKE_COMMAND}" -E env "CMAKE_BUILD_PARALLEL_LEVEL=${TELAR_GUI_QT_JOBS}"
      "${CMAKE_COMMAND}" --build "${build}" --target telar-qt --parallel 1
    COMMAND_ERROR_IS_FATAL ANY)
  set(TELAR_GUI_QT_PREFIX "${build}/install" CACHE INTERNAL "Resolved managed Qt installation" FORCE)
endfunction()

telar_prepare_qt()

# Drop old package locations when an existing build used Homebrew or a different
# managed Qt fingerprint. All Qt modules and host tools must come from this prefix.
get_cmake_property(cache_variables CACHE_VARIABLES)
foreach(variable IN LISTS cache_variables)
  if(variable MATCHES "^Qt6.*_DIR$")
    unset(${variable} CACHE)
    unset(${variable})
  endif()
endforeach()
set(Qt6_DIR "${TELAR_GUI_QT_PREFIX}/lib/cmake/Qt6" CACHE PATH "Managed Qt package" FORCE)
if(APPLE)
  set(MACDEPLOYQT_EXECUTABLE "${TELAR_GUI_QT_PREFIX}/bin/macdeployqt" CACHE FILEPATH "Managed Qt deployment tool" FORCE)
endif()
set(QT_HOST_PATH "")
set(QT_ADDITIONAL_PACKAGES_PREFIX_PATH "${TELAR_GUI_QT_PREFIX}")
list(PREPEND CMAKE_PREFIX_PATH "${TELAR_GUI_QT_PREFIX}")

function(telar_verify_qt_packages)
  get_cmake_property(variables CACHE_VARIABLES)
  set(prefix "${TELAR_GUI_QT_PREFIX}")
  foreach(variable IN LISTS variables)
    if(variable MATCHES "^Qt6.*_DIR$" AND NOT "${${variable}}" MATCHES "-NOTFOUND$")
      file(REAL_PATH "${${variable}}" package)
      cmake_path(IS_PREFIX prefix "${package}" NORMALIZE managed)
      if(NOT managed)
        message(FATAL_ERROR "${variable} resolved outside the managed Qt installation: ${package}")
      endif()
    endif()
  endforeach()
endfunction()
