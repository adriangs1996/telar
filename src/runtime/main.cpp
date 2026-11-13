#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

// Templates instantiated here use the SDK's static inline byte swaps; without a
// textual declaration clang emits them twice (duplicate _OSSwapInt32).
#include <arpa/inet.h>
#include <cstdio>

import std;
import telar.base.memory.allocators;
import telar.platform;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.cli.server;
import telar.runtime.plugins.run_worker;

auto main(int argc, char** argv) -> int {
  using namespace telar;
  using namespace telar::runtime;

  const std::span<char*> args(argv, argc);
  const std::string_view command = argc >= 2 ? args[1] : "";

  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
    BudgetAllocator budget{system, memory_budget};

    if (command == "traffic") {
      cli::runTraffic(budget, args.subspan<2>());
      return 0;
    }

    if (command == "plugin-worker") {
      cli::runPluginWorker(budget, cli::PluginWorkerOptions::parse(args.subspan<2>()));
      return 0;
    }

    if (command == plugins::TapWorkerOptions::command && argc >= 3) {
      const auto options = plugins::TapWorkerOptions::parse(args.subspan<2>());

      requireTracingBuild(options.trace_path != nullptr);
#if TELAR_DEBUG
      trace::Session tracing{budget, options.trace_path};

#endif
      plugins::runWorker(budget, options.entry, options.traffic);
      return 0;
    }

    SynchronizedAllocator memory{budget};

    cli::runServer(memory, cli::ServerOptions::parse(args.subspan<1>()));
    return 0;
  } catch (const SystemError& error) {
    std::fprintf(stderr, "telar runtime: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const TerminalError& error) {
    std::fprintf(stderr, "%s:%u: %s (%d)\n", error.location().file_name(), error.location().line(), error.what(), static_cast<int>(error.result()));
  } catch (const std::exception& error) {
    std::fprintf(stderr, "telar runtime: %s\n", error.what());
  }

  return 1;
}
