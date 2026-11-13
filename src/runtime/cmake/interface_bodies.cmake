get_filename_component(runtime_directory "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED RUNTIME_BUILD_DIRECTORY)
  set(RUNTIME_BUILD_DIRECTORY "${runtime_directory}/out")
endif()
get_filename_component(runtime_build_directory "${RUNTIME_BUILD_DIRECTORY}" ABSOLUTE)

if(NOT EXISTS "${runtime_build_directory}/compile_commands.json")
  message(FATAL_ERROR "No compile_commands.json in ${runtime_build_directory}; configure with tools/cpp configure runtime -B <directory> first")
endif()

include("${runtime_directory}/../../cmake/lifetime_check.cmake")
get_filename_component(allowlist "${runtime_directory}/../../docs/build/interface-bodies-allowlist.txt" ABSOLUTE)
telar_lifetime_jobs(jobs)
# Every module interface of the runtime's database: the runtime, the CLI and the telar libraries.
telar_interface_body_check("${runtime_directory}" "${runtime_build_directory}"
  "/(src/(runtime|cli)/|lib/(base|client|config|git|lua|machines|platform|plugins|render|shell|tls|vocabulary)/).*\\.cppm$"
  "/(src/(runtime|cli)/|lib/(base|client|config|git|lua|machines|platform|plugins|render|shell|tls|vocabulary)/)(.*/)?(tests|out(-[^/]*)?)/"
  "${jobs}"
  ALLOWLIST "${allowlist}")
