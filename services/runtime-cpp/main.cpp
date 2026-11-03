#include "cli/hook.hpp"
#include "cli/integration.hpp"
#include "cli/plugin.hpp"
#include "cli/plugin_worker.hpp"
#include "cli/proxy_trust.hpp"
#include "cli/server.hpp"
#include "cli/traffic.hpp"
#include "plugins/run_worker.hpp"
#include <cstdio>
#include <cstring>

auto main(int argc, char **argv) -> int {
  using namespace telar::runtime;

  std::span<char *> args(argv, argc);

  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
    BudgetAllocator budget{system, memory_budget};

    if (argc >= 2 && std::string_view{args.subspan<1>().front()} == "traffic") {
      cli::runTraffic(budget, args.subspan<2>());
      return 0;
    }

    if (argc >= 2 && std::string_view{args.subspan(1).front()} == "integration") {
      const auto options = cli::IntegrationOptions::parse(args.subspan<2>());
      return cli::runIntegration(budget, options);
    }

    if (argc >= 2 && std::string_view{args.subspan<1>().front()} == "hook") {
      const auto options = cli::HookOptions::parse(args.subspan<2>());
      return cli::runHook(budget, options, ProcessEnvironment{});
    }

    if (argc >= 2 && std::string_view{argv[1]} == "plugin") {
      const auto options = cli::PluginOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});
      cli::runPlugin(budget, options, ProcessEnvironment{});
      return 0;
    }

    if (argc >= 2 && std::string_view{argv[1]} == "plugin-worker") {
      cli::runPluginWorker(budget, cli::PluginWorkerOptions::parse(args.subspan<2>()));
      return 0;
    }

    if (argc >= 3 && std::string_view{argv[1]} == "tap-worker") {
      bool traffic = false;
      const char *trace_path = nullptr;
      for (int index = 3; index < argc; ++index) {
        const std::string_view option{argv[index]};
        if (option == "--traffic" && !traffic) { traffic = true; }
        else if (option == "--trace" && trace_path == nullptr && index + 1 < argc) { trace_path = argv[++index]; }
        else { throw std::invalid_argument{"Expected tap-worker ENTRY [--traffic] [--trace PATH]"}; }
      }

#if TELAR_DEBUG
      trace::Session tracing{budget, trace_path};
#else
      if (trace_path != nullptr) {
        throw std::invalid_argument{"Tracing is available in Debug builds only"};
      }
#endif
      plugins::runWorker(budget, argv[2], traffic);
      return 0;
    }

    SynchronizedAllocator memory{budget};
    if (argc >= 2 && std::string_view{argv[1]} == "proxy") {
      const auto options = cli::ProxyTrustOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});
      return cli::runProxyTrust(memory, options, ProcessEnvironment{});
    }

    const auto options = cli::ServerOptions::parse({argv + 1, static_cast<std::size_t>(argc - 1)});
    cli::runServer(memory, options);
    return 0;
  } catch (const std::invalid_argument &error) {
    std::fprintf(stderr, "telar runtime: %s\n", error.what());
    return 1;
  } catch (const SystemError &error) {
    std::fprintf(stderr, "telar runtime: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const TerminalError &error) {
    std::fprintf(stderr, "%s:%u: %s (%d)\n", error.location().file_name(), error.location().line(), error.what(), static_cast<int>(error.result()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar runtime: %s\n", error.what());
  }

  return 1;
}
