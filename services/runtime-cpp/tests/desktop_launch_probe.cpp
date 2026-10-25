#include "runtime_endpoint.hpp"
#include <cstdio>
#include <exception>

int main() {
  try {
    const auto socket = runtime_endpoint::resolve();
    std::printf("%s\n", socket.c_str());
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
