include_guard(GLOBAL)

if(POLICY CMP0218)
  cmake_policy(SET CMP0218 NEW)
endif()
set(QT_NO_PRIVATE_MODULE_WARNING ON)

include("${CMAKE_CURRENT_LIST_DIR}/../../../cmake/managed_build.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/qt/manifest.cmake")

# Keep Qt's QML examples and fuzz fixtures outside this QML project's source tree.
set(TELAR_GUI_QT_BUILD_DIR "${TELAR_ROOT}/.qt-cache" CACHE PATH "Managed Qt source, build and installation cache")
set(TELAR_GUI_QT_JOBS 2 CACHE STRING "Parallel compiler jobs when building Qt")

function(telar_prepare_qt)
  file(MAKE_DIRECTORY "${TELAR_GUI_QT_BUILD_DIR}")
  file(REAL_PATH "${TELAR_GUI_QT_BUILD_DIR}" root)
  file(REAL_PATH "${CMAKE_CURRENT_SOURCE_DIR}" source)
  cmake_path(IS_PREFIX source "${root}" NORMALIZE inside_source)
  if(inside_source)
    message(FATAL_ERROR "TELAR_GUI_QT_BUILD_DIR must be outside the GUI source tree so QML import scanning cannot inspect Qt's own fixtures")
  endif()

  telar_managed_build(NAME "Qt ${TELAR_QT_VERSION}" RECIPE "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/qt" ROOT "${root}"
    TARGET telar-qt JOBS "${TELAR_GUI_QT_JOBS}" FILES CMakeLists.txt manifest.cmake patch.cmake RESULT prefix)
  set(TELAR_GUI_QT_PREFIX "${prefix}" CACHE INTERNAL "Resolved managed Qt installation" FORCE)
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
