#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.sys.posix;
import telar.base.memory.allocators;
import telar.platform.error;
import telar.platform.paths;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.server.server;
import telar.runtime.plugins.run_worker;
import telar.runtime.plugins.worker;
import telar.runtime.terminal.ghostty;

namespace {

  // Prints the failure that ended the runtime on stderr, as each kind of failure reads.
  void reportFailure(const std::exception& error) {
    using namespace telar;
    using namespace telar::runtime;

    if (const auto* system = dynamic_cast<const SystemError*>(&error)) {
      std::println(stderr, "telar runtime: {}: {}", system->what(), std::system_category().message(system->code()));
    } else if (const auto* terminal = dynamic_cast<const TerminalError*>(&error)) {
      std::println(stderr, "{}:{}: {} ({})", terminal->location().file_name(), terminal->location().line(), terminal->what(), static_cast<int>(terminal->result()));
    } else {
      std::println(stderr, "telar runtime: {}", error.what());
    }
  }

}

auto main(int argc, char** argv) -> int {
  using namespace telar;
  using namespace telar::runtime;

  // main receives its arguments as the C array and count the C runtime gives it.
#pragma clang unsafe_buffer_usage begin
  const std::span<char*> args(argv, static_cast<std::size_t>(argc));
#pragma clang unsafe_buffer_usage end
  const std::string_view command = argc >= 2 ? args[1] : "";

  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
    BudgetAllocator budget{system, memory_budget};
    MemoryAdapter budget_memory{budget};
    Memory& memory = budget_memory;

    if (command == "traffic") {
      cli::runTraffic(memory, args.subspan<2>());
      return 0;
    }

    if (command == "plugin-worker") {
      cli::runPluginWorker(memory, cli::PluginWorkerOptions::parse(args.subspan<2>()));
      return 0;
    }

    if (command == plugins::TapWorkerOptions::command && argc >= 3) {
      const auto options = plugins::TapWorkerOptions::parse(args.subspan<2>());

      requireTracingBuild(options.trace_path != nullptr);
#if TELAR_DEBUG
      const trace::Session tracing{memory, options.trace_path};

#endif
      plugins::runWorker(memory, options.entry, options.traffic);
      return 0;
    }

    // The server shares its allocator with its worker threads.
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter synchronized_memory{synchronized};
    ConcurrentMemory& shared = synchronized_memory;

    cli::runServer(shared, cli::ServerOptions::parse(args.subspan<1>()));
    return 0;
  } catch (const std::exception& error) {
    try {
      reportFailure(error);
    } catch (const std::exception&) {
      // stderr refused the report too, and nothing is left to tell it to.
      return 1;
    }
  }

  return 1;
}
