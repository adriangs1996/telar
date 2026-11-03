#include "hook.hpp"
#include "integration.hpp"
#include "plugin.hpp"
#include "proxy_trust.hpp"
#include "server.hpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <span>
#include <string_view>

namespace {

constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;

}

auto main(int argc, char **argv) -> int {
  using namespace telar::runtime;

  const std::span<char *const> arguments{argv, static_cast<std::size_t>(argc)};

  try {
    SystemAllocator system;
    BudgetAllocator budget{system, memory_budget};
    const std::string_view command = arguments.size() >= 2 ? arguments[1] : "";
    const auto options = arguments.subspan(std::min<std::size_t>(2, arguments.size()));

    if (command == "hook") {
      return cli::runHook(budget, cli::HookOptions::parse(options), ProcessEnvironment{});
    }

    if (command == "integration") {
      return cli::runIntegration(budget, cli::IntegrationOptions::parse(options));
    }

    if (command == "plugin") {
      cli::runPlugin(budget, cli::PluginOptions::parse(options), ProcessEnvironment{});
      return 0;
    }

    if (command == "proxy") {
      SynchronizedAllocator memory{budget};
      return cli::runProxyTrust(memory, cli::ProxyTrustOptions::parse(options), ProcessEnvironment{});
    }

    if (command == "server") {
      cli::runServer(budget, arguments.subspan(1));
      return 0;
    }

    throw std::invalid_argument{"Expected hook, integration, plugin, proxy or server"};
  } catch (const std::invalid_argument &error) {
    std::fprintf(stderr, "telar: %s\n", error.what());
    return 1;
  } catch (const SystemError &error) {
    std::fprintf(stderr, "telar: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar: %s\n", error.what());
  }

  return 1;
}
