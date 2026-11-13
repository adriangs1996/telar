file(READ "${CMAKE_CURRENT_SOURCE_DIR}/machines/probe.sh" TELAR_MACHINE_PROBE)
# The installer machine setup runs there is the release installer itself.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../../install.sh" TELAR_MACHINE_INSTALLER)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/machines/probe.sh" "${CMAKE_CURRENT_SOURCE_DIR}/../../install.sh")
configure_file(machines/assets.hpp.in "${CMAKE_CURRENT_BINARY_DIR}/generated/machine_assets.hpp" @ONLY)
