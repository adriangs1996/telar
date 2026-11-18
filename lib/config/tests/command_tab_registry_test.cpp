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
import telar.base.text.utf8;
import telar.base.ds;

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
      const ds::Array<std::string_view, 2> arguments{"echo", "value"};

      check(commands->keep(arguments, {}, limits));
      const auto saved = commands->checkpoint();

      check(commands->keep(arguments, {}, limits));
      check(commands->checkpoint().rows == saved.rows && commands->checkpoint().bytes == saved.bytes);
      check(commands->keep(arguments, "named", limits));
      check(commands->checkpoint().rows == 2);
      commands->restore(saved);
      check(commands->checkpoint().rows == 1);

      ds::Array<char, 16> label;

      for (std::size_t index = saved.rows; index < 768; ++index) {
        const auto length = std::snprintf(label.dataMut(), label.size(), "%zu", index);

        check(commands->keep(arguments, {label.data(), static_cast<std::size_t>(length)}, limits));
      }

      check(!commands->keep(arguments, "excess", limits));
      check(limits.entries().size() == 1 && limits.entries()[0].name == "config.command_tab_rows");
      check(commands->keep(arguments, {}, limits));

      commands->restore(saved);
      ds::Array<char, 4096> bytes;

      bytes.fill('x');
      const ds::Array<std::string_view, 1> large{std::string_view{bytes.data(), bytes.size()}};

      for (std::size_t index = 0; index < 19; ++index) {
        const auto length = std::snprintf(label.dataMut(), label.size(), "%zu", index);

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

  // A row past CommandTabView's bounds would be encoded past the row buffer; keepReference
  // refuses it and keeps nothing.
  void testCommandTabRejectsInvalidRows() {
    SystemAllocator system;
    BudgetAllocator memory{system, 128 * 1024};

    {
      auto commands = makeOwned<config::CommandTabRegistry>(memory);
      config::LimitNotices limits;
      const ds::Array<std::string_view, 1> kept{"echo"};

      check(commands->keep(kept, {}, limits));
      const auto saved = commands->checkpoint();
      const ds::Array<std::string_view, 33> too_many{"a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a", "a"};
      const std::string long_label(33, 'l');
      const ds::Array<std::string_view, 2> empty_argument{"echo", ""};
      const ds::Array<std::string_view, 2> nul_argument{"echo", std::string_view{"a\0b", 3}};
      const std::string half(2048, 'x');
      const std::string other_half(2049, 'y');
      const ds::Array<std::string_view, 2> too_long{half, other_half};

      const auto refused = [&](std::span<const std::string_view> arguments, std::string_view label) {
        try {
          static_cast<void>(commands->keepReference(arguments, label, limits));
        } catch (const EncodingError&) {
          const auto after = commands->checkpoint();

          return after.rows == saved.rows && after.bytes == saved.bytes;
        }

        return false;
      };

      check(refused({}, {}));
      check(refused(too_many, {}));
      check(refused(kept, long_label));
      check(refused(empty_argument, {}));
      check(refused(nul_argument, {}));
      check(refused(too_long, {}));
      check(commands->keep(std::span{too_many}.first(32), std::string_view{long_label}.substr(1), limits));
      const ds::Array<std::string_view, 2> fits{half, std::string_view{other_half}.substr(1)};

      check(commands->keep(fits, {}, limits));
    }

    check(memory.liveBytes() == 0);
  }

  const telar::testing::Case case_command_tab_registry{"command_tab_registry.limits", testCommandTabRegistry};
  const telar::testing::Case case_command_tab_invalid_rows{"command_tab_registry.rejects_invalid_rows", testCommandTabRejectsInvalidRows};

}
