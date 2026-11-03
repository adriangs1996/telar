#include "plugins/package_snapshots.hpp"
#include "telar_platform/write_descriptor.hpp"
#include "telar_plugins/inspection.hpp"
#include "telar_plugins/package_inspector.hpp"
#include <cstdio>

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
