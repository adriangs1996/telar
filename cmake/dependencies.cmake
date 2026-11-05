include_guard(GLOBAL)

# Where the pinned native dependencies other than Qt build, once, for every
# C++ project in the repository.
include("${CMAKE_CURRENT_LIST_DIR}/managed_build.cmake")

get_filename_component(telar_repository "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(TELAR_DEPENDENCIES_DIR "${telar_repository}/.dependencies-cache" CACHE PATH "Managed native dependency sources, builds and installations")
cmake_host_system_information(RESULT telar_processors QUERY NUMBER_OF_LOGICAL_CORES)
set(TELAR_DEPENDENCIES_JOBS "${telar_processors}" CACHE STRING "Parallel compiler jobs when building managed dependencies")
