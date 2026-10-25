#include "cli/hook.hpp"
#include "cli/integration.hpp"
#include "cli/plugin.hpp"
#include "cli/proxy_trust.hpp"
#include "cli/server.hpp"
#include "plugins/run_worker.hpp"
#include <cstdio>
#include <cstring>

int main(int argc, char **argv) {
  using namespace telar::runtime;
  try {
    SystemAllocator system;
    constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;
    BudgetAllocator budget{system, memory_budget};

    if (argc >= 2 && std::string_view{argv[1]} == "integration") {
      const auto options = cli::IntegrationOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});
      return cli::runIntegration(budget, options);
    }

    if (argc >= 2 && std::string_view{argv[1]} == "hook") {
      const auto options = cli::HookOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});
      return cli::runHook(budget, options, ProcessEnvironment{});
    }

    if (argc >= 2 && std::string_view{argv[1]} == "plugin") {
      const auto options = cli::PluginOptions::parse({argv + 2, static_cast<std::size_t>(argc - 2)});
      cli::runPlugin(budget, options, ProcessEnvironment{});
      return 0;
    }

    if (argc >= 3 && std::string_view{argv[1]} == "tap-worker") {
      if (argc != 3 && (argc != 5 || std::string_view{argv[3]} != "--trace")) {
        throw std::invalid_argument{"Expected tap-worker ENTRY [--trace PATH]"};
      }

#if TELAR_DEBUG
      trace::Session tracing{budget, argc == 5 ? argv[4] : nullptr};
#else
      if (argc == 5) {
        throw std::invalid_argument{"Tracing is available in Debug builds only"};
      }
#endif
      plugins::runWorker(budget, argv[2]);
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
