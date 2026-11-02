cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/manifest.cmake")

file(MAKE_DIRECTORY "${DOWNLOAD_DIR}")
set(patch_file "${DOWNLOAD_DIR}/CVE-2026-105924-qtbase-6.12.diff")
set(valid FALSE)
if(EXISTS "${patch_file}")
  file(SHA256 "${patch_file}" digest)
  if(digest STREQUAL TELAR_QT_PATCH_SHA256)
    set(valid TRUE)
  endif()
endif()
if(NOT valid)
  file(DOWNLOAD "${TELAR_QT_PATCH_URL}" "${patch_file}"
    EXPECTED_HASH "SHA256=${TELAR_QT_PATCH_SHA256}"
    TLS_VERIFY ON)
endif()

# ExternalProject can repeat its patch step after a dependency update.
set(marker "${SOURCE_DIR}/.telar-patch-${TELAR_QT_PATCH_SHA256}")
if(NOT EXISTS "${marker}")
  execute_process(COMMAND "${PATCH_EXECUTABLE}" -p1 -i "${patch_file}"
    WORKING_DIRECTORY "${SOURCE_DIR}" COMMAND_ERROR_IS_FATAL ANY)
  file(WRITE "${marker}" "${TELAR_QT_PATCH_SHA256}\n")
endif()
