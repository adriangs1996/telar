# Its own target, without zlib, so the CLI links it and not the native reader.
telar_add_library(telar-git-checkout
  SOURCES checkout.cpp
  DEPS telar::platform)
target_compile_options(telar-git-checkout PRIVATE -Wall -Wextra -Wpedantic)
