# The processes the TELAR_BUILD_* options select. The runtime comes before the CLI,
# whose tests that start a runtime need it.

if(TELAR_LINUX_DISTRIBUTABLE)
  # musl gives threads 128 KiB stacks unless the executable names a size;
  # the terminal engine needs glibc's 8 MiB.
  add_link_options(-static "LINKER:-z,stack-size=8388608")
endif()

if(TELAR_BUILD_RUNTIME)
  add_subdirectory(runtime)
endif()
if(TELAR_BUILD_CLI)
  add_subdirectory(cli)
endif()

# The installed executables may link only the base system (glibc on Linux);
# every distributable build checks it.
if(TELAR_BUILD_RUNTIME AND TELAR_RUNTIME_DISTRIBUTABLE)
  set(TELAR_LINKAGE_KIND "$<IF:$<PLATFORM_ID:Darwin>,macos,linux-headless>")
  add_custom_target(distributable-linkage ALL
    COMMAND "${CMAKE_COMMAND}" -E env "TELAR_MACOS_MIN=${CMAKE_OSX_DEPLOYMENT_TARGET}"
            "${PROJECT_SOURCE_DIR}/packaging/release/check-linkage.sh" "${TELAR_LINKAGE_KIND}"
            "$<TARGET_FILE:telar-runtime>" "$<TARGET_FILE:telar>" "$<TARGET_FILE:telar-config-check>"
    DEPENDS telar-runtime telar telar-config-check
    VERBATIM)
endif()

if(TELAR_BUILD_GUI)
  add_subdirectory(gui)
endif()
if(TELAR_BUILD_AUTH)
  add_subdirectory(auth-daemon)
endif()
