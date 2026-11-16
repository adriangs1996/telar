include_guard(GLOBAL)

# libghostty-vt as deps::ghostty_vt: the static library and headers that
# `tools/cpp vt` installs into GHOSTTY_VT_ROOT. Every project finds it here.
set(GHOSTTY_VT_ROOT "" CACHE PATH "Installed libghostty-vt prefix")
find_path(GHOSTTY_VT_INCLUDE_DIR ghostty/vt.h HINTS "${GHOSTTY_VT_ROOT}/include" REQUIRED)
find_library(GHOSTTY_VT_LIBRARY NAMES libghostty-vt.a HINTS "${GHOSTTY_VT_ROOT}/lib" REQUIRED)

add_library(deps::ghostty_vt UNKNOWN IMPORTED GLOBAL)
set_target_properties(deps::ghostty_vt PROPERTIES
  IMPORTED_LOCATION "${GHOSTTY_VT_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${GHOSTTY_VT_INCLUDE_DIR}")
