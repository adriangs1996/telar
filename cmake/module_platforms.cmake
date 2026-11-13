# Native-only interfaces; portable facades guard their native declarations.
set(TELAR_MACOS_MODULES
  lib/sys/apple/apple.cppm
  src/runtime/redirect/record/record.cppm
)
set(TELAR_LINUX_MODULES
  lib/sys/linux/linux.cppm
)
