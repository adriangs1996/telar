#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.sys.posix;
import telar.cli.commands.tab;
import telar.cli.commands.window;

int main(int argc, char** argv) {
  using namespace telar::runtime::cli;

  // main receives its arguments as the C array and count the C runtime gives it.
#pragma clang unsafe_buffer_usage begin
  const std::span<char* const> arguments{argv, static_cast<std::size_t>(argc)};
#pragma clang unsafe_buffer_usage end

  try {
    return checkConfiguration(window::ConfigCheckOptions::parse(arguments.subspan(1)));
  } catch (const std::exception& error) {
    std::println(stderr, "telar config: {}", error.what());
    return 1;
  }
}
