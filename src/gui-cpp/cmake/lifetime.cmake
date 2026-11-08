get_filename_component(gui_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED GUI_BUILD_DIRECTORY)
  set(GUI_BUILD_DIRECTORY "${gui_directory}/out")
endif()
get_filename_component(gui_build_directory "${GUI_BUILD_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${gui_build_directory}/compile_commands.json")
  message(FATAL_ERROR "Configure gui-cpp before running gui-lifetime")
endif()

include("${gui_directory}/../../cmake/lifetime_check.cmake")
telar_lifetime_jobs(jobs)
telar_lifetime_check("${gui_directory}" "${gui_build_directory}"
  "/src/gui-cpp/.*\\.(cpp|cppm|mm)$"
  "/src/gui-cpp/(.*/)?(tests|out[^/]*)/"
  "${jobs}")
