#include "core/memory.hpp"
#include "plugins/inspection.hpp"
#include "plugins/package_inspection.hpp"
#include "qt/plugin_packages.hpp"
#include <QCoreApplication>
#include <cstddef>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  try {
    if (argc != 4 || std::string_view{argv[1]} != "plugin" || std::string_view{argv[2]} != "inspect") {
      throw std::invalid_argument{"Expected plugin inspect PATH"};
    }

    telar::gui::SystemAllocator system;
    constexpr std::size_t budget = std::size_t{64} * 1024 * 1024;
    telar::gui::BudgetAllocator memory{system, budget};
    using Inspector = telar::runtime::plugins::PackageInspection<telar::gui::qt::PluginPackageHash>;
    const auto package = Inspector::inspect(memory, argv[3]);
    telar::gui::String<decltype(memory)> output{telar::gui::AllocatorRef<char, decltype(memory)>{memory}};
    telar::runtime::plugins::appendInspection(output, package);
    std::cout.write(output.data(), static_cast<std::streamsize>(output.size()));
    if (!std::cout.good()) {
      throw std::runtime_error{"Write package inspection"};
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
