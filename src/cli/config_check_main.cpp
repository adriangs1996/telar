#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstdio>

import std;
import telar.client.protocol;
import telar.cli.tab;

int main(int argc, char **argv) {
  using namespace telar::runtime::cli;
  try {
    return checkConfiguration(window::ConfigCheckOptions::parse(std::span<char *const>{argv, static_cast<std::size_t>(argc)}.subspan(1)));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar config: %s\n", error.what());
    return 1;
  }
}
