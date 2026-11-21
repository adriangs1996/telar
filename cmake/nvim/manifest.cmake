# The Neovim telar provisions on a host that has none: one release, and each of its archives
# by the SHA-256 it must have. `telar integration install editor` fetches the one of its host
# from the release's own page and refuses any other bytes; the runtime looks for the version
# it names under its data directory.
set(TELAR_NVIM_VERSION "0.12.5")
set(TELAR_NVIM_SHA256_LINUX_X86_64 "bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875")
set(TELAR_NVIM_SHA256_LINUX_ARM64 "1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725")
set(TELAR_NVIM_SHA256_MACOS_ARM64 "65fb000099e47ca1b762584c484cc833f40e30851a0ec450d4174e16317c1f9b")
set(TELAR_NVIM_SHA256_MACOS_X86_64 "81f4518622cb059b450ee2e498c6a1082a222f6bd89589de5bbcf0c6a68aa3fd")
