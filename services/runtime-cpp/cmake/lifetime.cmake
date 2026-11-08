get_filename_component(runtime_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED RUNTIME_BUILD_DIRECTORY)
  set(RUNTIME_BUILD_DIRECTORY "${runtime_directory}/out")
endif()
get_filename_component(runtime_build_directory "${RUNTIME_BUILD_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${runtime_build_directory}/compile_commands.json")
  message(FATAL_ERROR "No compile_commands.json in ${runtime_build_directory}; configure with tools/cpp configure runtime -B <directory> first")
endif()

include("${runtime_directory}/../../cmake/lifetime_check.cmake")
telar_lifetime_jobs(jobs)
# The runtime's database also compiles the CLI and the telar libraries it links.
telar_lifetime_check("${runtime_directory}" "${runtime_build_directory}"
  "/(services/(runtime|cli)-cpp/|dlls/telar-[a-z]+/).*\\.(cpp|cppm)$"
  "/(services/(runtime|cli)-cpp/|dlls/telar-[a-z]+/)(.*/)?(tests|out[^/]*)/"
  "${jobs}")
