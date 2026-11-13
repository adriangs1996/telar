get_filename_component(gui_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED GUI_BUILD_DIRECTORY)
  set(GUI_BUILD_DIRECTORY "${gui_directory}/out")
endif()
get_filename_component(gui_build_directory "${GUI_BUILD_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${gui_build_directory}/compile_commands.json")
  message(FATAL_ERROR "Configure gui-cpp before running gui-interface-bodies")
endif()

include("${gui_directory}/../../cmake/lifetime_check.cmake")
get_filename_component(allowlist "${gui_directory}/../../docs/build/interface-bodies-allowlist.txt" ABSOLUTE)
telar_lifetime_jobs(jobs)
# The probe fixtures under tools/ are built only with the tests, as those under tests/.
telar_interface_body_check("${gui_directory}" "${gui_build_directory}"
  "/src/gui/.*\\.cppm$"
  "/src/gui/((.*/)?(tests|out(-[^/]*)?)|tools)/"
  "${jobs}"
  ALLOWLIST "${allowlist}")
