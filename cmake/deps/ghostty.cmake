include_guard(GLOBAL)

# libghostty-vt as deps::ghostty_vt: the static library and headers that
# `tools/cpp vt` installs into GHOSTTY_VT_ROOT. Every project finds it here.
set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
# Another prefix is found again, and the checks that compiled against the old one rerun.
if(GHOSTTY_VT_ROOT AND NOT "${GHOSTTY_VT_ROOT}" STREQUAL "${TELAR_LAST_GHOSTTY_VT_ROOT}")
  foreach(variable IN ITEMS GHOSTTY_VT_INCLUDE_DIR GHOSTTY_VT_LIBRARY GHOSTTY_VT_HAS_RUNTIME_STORAGE_STATE GHOSTTY_VT_HAS_WUFFS_PNG)
    unset(${variable} CACHE)
  endforeach()
endif()
set(TELAR_LAST_GHOSTTY_VT_ROOT "${GHOSTTY_VT_ROOT}" CACHE INTERNAL "Prefix used for the VT checks" FORCE)
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
find_library(GHOSTTY_VT_LIBRARY NAMES libghostty-vt.a HINTS "${GHOSTTY_VT_ROOT}/lib" REQUIRED)

add_library(deps::ghostty_vt UNKNOWN IMPORTED GLOBAL)
set_target_properties(deps::ghostty_vt PROPERTIES
  IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")
