module;
#include <cstdio>
#include <cstdlib>

export module telar.cli.tests.check;

import std;

export {
inline void check(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    std::fprintf(stderr, "%s:%u: check failed\n", location.file_name(), location.line());
    std::abort();
  }
}
}
