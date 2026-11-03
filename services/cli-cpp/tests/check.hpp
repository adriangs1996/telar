#pragma once

#include <cstdio>
#include <cstdlib>
#include <source_location>

inline void check(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    std::fprintf(stderr, "%s:%u: check failed\n", location.file_name(), location.line());
    std::abort();
  }
}
