#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.config.client;
import telar.config.core;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;
  using namespace telar;

  void testCommandTabRegistry() {
    SystemAllocator system;
    BudgetAllocator memory{system, 128 * 1024};

    {
      auto commands = makeOwned<config::CommandTabRegistry>(memory);
      config::LimitNotices limits;
      const std::array<std::string_view, 2> arguments{"echo", "value"};

      check(commands->keep(arguments, {}, limits));
      const auto saved = commands->checkpoint();

      check(commands->keep(arguments, {}, limits));
      check(commands->checkpoint().rows == saved.rows && commands->checkpoint().bytes == saved.bytes);
      check(commands->keep(arguments, "named", limits));
      check(commands->checkpoint().rows == 2);
      commands->restore(saved);
      check(commands->checkpoint().rows == 1);

      std::array<char, 16> label;

      for (std::size_t index = saved.rows; index < 768; ++index) {
        const auto length = std::snprintf(label.data(), label.size(), "%zu", index);

        check(commands->keep(arguments, {label.data(), static_cast<std::size_t>(length)}, limits));
      }

      check(!commands->keep(arguments, "excess", limits));
      check(limits.entries().size() == 1 && limits.entries()[0].name == "config.command_tab_rows");
      check(commands->keep(arguments, {}, limits));

      commands->restore(saved);
      std::array<char, 4096> bytes;

      bytes.fill('x');
      const std::array<std::string_view, 1> large{std::string_view{bytes.data(), bytes.size()}};

      for (std::size_t index = 0; index < 19; ++index) {
        const auto length = std::snprintf(label.data(), label.size(), "%zu", index);

        check(commands->keep(large, {label.data(), static_cast<std::size_t>(length)}, limits));
      }

      check(!commands->keep(large, "excess", limits));
      check(limits.entries().size() == 2 && limits.entries()[1].name == "config.command_tab_bytes");
      check(!commands->keep(large, "excess", limits) && !limits.entries()[1].requested);
      commands->restore(saved);
      check(commands->keep(large, {}, limits));
    }

    check(memory.liveBytes() == 0);
  }

  const telar::testing::Case case_command_tab_registry{"command_tab_registry.limits", testCommandTabRegistry};

}
