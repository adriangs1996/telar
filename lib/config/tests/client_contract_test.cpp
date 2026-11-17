#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <lua.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.lua;
import telar.config.client;
import telar.config.core;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // The GUI writes `telar plugin-worker` with eachArgument and the runtime reads it with parse,
  // so what one writes the other must read back as the same invocation.
  void testPluginWorkerArgumentsRoundTrip() {
    for (const bool sidebar : {true, false}) {
      const config::PluginWorkerOptions written{
          .entry = "/plugins/demo/main.lua",
          .action = "demo.run-1_x",
          .context = {
              .sidebar_visible = sidebar,
              .tab_count = std::numeric_limits<std::uint16_t>::max(),
              .active_tab_index = 7,
              .pane_count = 1,
              .focused_pane_id = std::numeric_limits<std::uint64_t>::max(),
          },
      };

      std::array<std::string, config::PluginWorkerOptions::argument_count + 1> words;
      std::size_t count = 0;

      written.eachArgument([&](std::string_view word) {
        check(count < words.size());
        words[count++].assign(word);
      });

      check(count == config::PluginWorkerOptions::argument_count);
      std::array<char*, config::PluginWorkerOptions::argument_count> argv{};

      for (std::size_t index = 0; index < argv.size(); ++index) {
        argv[index] = words[index].data();
      }

      const auto read = config::PluginWorkerOptions::parse(argv);

      check(std::string_view{read.entry} == written.entry);
      check(std::string_view{read.action} == written.action);
      check(read.context.sidebar_visible == sidebar);
      check(read.context.tab_count == written.context.tab_count);
      check(read.context.active_tab_index == written.context.active_tab_index);
      check(read.context.pane_count == written.context.pane_count);
      check(read.context.focused_pane_id == written.context.focused_pane_id);
    }
  }

  // A command tab reference turns back into the argv the GUI launches: an argument longer than
  // 255 bytes needs both bytes of its length, and the label follows every argument.
  void testCommandTabReferenceLoadsLongArguments() {
    SystemAllocator system;
    BudgetAllocator memory{system, 256 * 1024};

    {
      auto commands = makeOwned<config::CommandTabRegistry>(memory);
      config::LimitNotices limits;
      std::string long_argument(300, 'a');

      for (std::size_t index = 0; index < long_argument.size(); ++index) {
        long_argument[index] = static_cast<char>('a' + (index % 26));
      }

      const std::array<std::string_view, 3> arguments{"sh", long_argument, "-c"};
      const std::string_view label = "a label of exactly thirty-two by";
      const auto reference = commands->keepReference(arguments, label, limits);

      check(reference.has_value());
      const auto loaded = commands->load(*reference);

      check(loaded.has_value());
      check(loaded->argv().size() == arguments.size());
      for (std::size_t index = 0; index < arguments.size(); ++index) {
        check(loaded->argv()[index] == arguments[index]);
      }

      check(loaded->label() == label);
    }

    check(memory.liveBytes() == 0);
  }

  // Runs `source` and hands what it returned to `consume`.
  template <typename Consume>
  void withResult(std::string_view source, Consume&& consume) {
    SystemAllocator system;
    MemoryAdapter memory{system};
    lua::Vm<Memory> vm{memory};

    vm.execute(source, "@result.lua");
    const lua::Value result{vm.state(), -1, "result"};

    consume(result);
  }

  bool decisionRefused(std::string_view source) {
    bool refused = false;

    withResult(source, [&](const lua::Value& result) {
      try {
        static_cast<void>(config::CallbackResultReader::decision(result));
      } catch (const lua::Error&) {
        refused = true;
      }
    });

    return refused;
  }

  // A binding's function decides what its keys become; the reader refuses a decision that
  // does not fit InputDecisionSetting rather than writing past its sixteen keys.
  void testInputDecisionBounds() {
    check(decisionRefused("return {input_kind = 'keys', keys = {}}"));
    check(decisionRefused("local keys = {} for i = 1, 17 do keys[i] = 'a' end return {input_kind = 'keys', keys = keys}"));
    check(decisionRefused("return {input_kind = 'nope'}"));
    check(decisionRefused("return {input_kind = 'consume', extra = 1}"));

    withResult("local keys = {} for i = 1, 16 do keys[i] = 'a' end return {input_kind = 'keys', keys = keys}", [](const lua::Value& result) {
      const auto decision = config::CallbackResultReader::decision(result);

      check(decision.kind == config::InputDecisionSetting::Kind::keys);
      check(decision.length == 16);
    });
  }

  const telar::testing::Case case_plugin_worker_arguments{"client.plugin_worker_arguments_round_trip", testPluginWorkerArgumentsRoundTrip};
  const telar::testing::Case case_command_tab_long_arguments{"client.command_tab_reference_loads_long_arguments", testCommandTabReferenceLoadsLongArguments};
  const telar::testing::Case case_input_decision_bounds{"client.input_decision_bounds", testInputDecisionBounds};

}
