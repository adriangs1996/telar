#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include "telar_base/memory/allocator.hpp"
#include "telar_platform/open_directory.h"
#include "telar_base/memory/fixed_text.hpp"
#include <charconv>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <cstddef>
#include <unistd.h>
#include <openssl/sha.h>
#include <chrono>
#include <concepts>
#include <limits>
#include <cstdio>



import telar.runtime.plugins.tap_configuration;
import telar.platform;
import telar.plugins;

using namespace telar;
using namespace telar::runtime;

int main(int argc, char **argv) {
  try {
    if (argc != 4 || std::string_view{argv[1]} != "plugin" || (std::string_view{argv[2]} != "inspect" && std::string_view{argv[2]} != "snapshot")) {
      throw std::invalid_argument{"Expected plugin inspect|snapshot PATH"};
    }
    SystemAllocator system;
    BudgetAllocator memory{system, 64 * 1024 * 1024};
    auto package = plugins::PackageInspector::inspect(memory, argv[3]);
    plugins::PackageSnapshots snapshots{memory};
    if (std::string_view{argv[2]} == "snapshot") {
      package = snapshots.copy(package, 0);
    }
    String<decltype(memory)> output{AllocatorRef<char, decltype(memory)>{memory}};
    plugins::appendInspection(output, package);
    const auto error = writeDescriptor(STDOUT_FILENO, {reinterpret_cast<const std::uint8_t *>(output.data()), output.size()});
    if (error != 0) {
      throw SystemError{"Write package inspection", error};
    }
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "plugin-package-probe: %s\n", error.what());
    return 1;
  }
}
