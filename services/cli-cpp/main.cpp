#include "command_error.hpp"
#include "help.hpp"
#include "hook.hpp"
#include "integration.hpp"
#include "integration_assets.hpp"
#include "launch_commands.hpp"
#include "plugin.hpp"
#include "proxy_trust.hpp"
#include "server.hpp"
#include <cstdio>
#include <cstring>
#include <span>
#include <string_view>

namespace telar::runtime::cli {
namespace {

constexpr std::size_t memory_budget = std::size_t{2} * 1024 * 1024 * 1024;

// A family or entry point this build does not implement yet: the C++ CLI is
// replacing the Zig one family by family (see parity.md).
int unavailable(std::string_view what) {
  std::fprintf(stderr, "telar: %.*s is not implemented by this telar yet\n", static_cast<int>(what.size()), what.data());
  return 1;
}

int printSkill(std::span<char *const> words) {
  const std::string_view which = words.size() > 1 ? words[1] : "telar";
  if (which != "telar" && which != "coordinator") {
    throw std::invalid_argument{"--skill takes telar or coordinator"};
  }

  const auto text = which == "telar" ? integration::assets::telar_skill : integration::assets::coordinator_skill;
  std::fwrite(text.data(), 1, text.size(), stdout);
  return 0;
}

int runFamily(BudgetAllocator<SystemAllocator> &memory, Family family, std::span<char *const> words) {
  const auto options = words.subspan(1);
  switch (family) {
  case Family::machine:
    return runMachineCommand(memory, options);
  case Family::cli:
    return runCliCommand(options);
  case Family::gui:
    return runWindowCommand(memory, options, true);
  case Family::hook:
    return runHook(memory, HookOptions::parse(options), ProcessEnvironment{});
  case Family::integration:
    return runIntegration(memory, IntegrationOptions::parse(options));
  case Family::plugin:
    runPlugin(memory, PluginOptions::parse(options), ProcessEnvironment{});
    return 0;
  case Family::proxy: {
    SynchronizedAllocator synchronized{memory};
    return runProxyTrust(synchronized, ProxyTrustOptions::parse(options), ProcessEnvironment{});
  }
  case Family::server:
    runServer(memory, words);
    return 0;
  default:
    return unavailable(std::string{"telar "} + std::string{familyName(family)});
  }
}

int run(std::span<char *const> words);

int runResolved(std::span<char *const> words) {
  try {
    return run(words);
  } catch (const std::invalid_argument &error) {
    const auto reference = helpReference(words);
    std::fprintf(stderr, "telar: %s; see `%s`\n", error.what(), reference.c_str());
    return 1;
  }
}

int run(std::span<char *const> words) {
  if (const auto topic = findHelp(words)) {
    const auto text = helpText(*topic).value_or(helpText({}).value_or(""));
    std::fwrite(text.data(), 1, text.size(), stdout);
    return 0;
  }

  if (!words.empty() && (std::string_view{words.front()} == "--machine" || std::string_view{words.front()}.starts_with("--machine="))) {
    return dispatchMachine(words, runResolved);
  }

  if (!words.empty() && std::string_view{words.front()} == "dispatch-argv") {
    return dispatchArguments(words.subspan(1), runResolved);
  }

  if (words.empty()) {
    SystemAllocator system;
    BudgetAllocator memory{system, memory_budget};
    return runWindowCommand(memory, words, false);
  }

  const std::string_view first = words.front();
  if (first == "--version" || first == "-V") {
    std::printf("telar %.*s\n", static_cast<int>(version.size()), version.data());
    return 0;
  }

  if (first == "--skill") {
    return printSkill(words);
  }

  SystemAllocator system;
  BudgetAllocator memory{system, memory_budget};
  // The GUI runs plugin actions through `telar plugin-worker`; the worker lives in the runtime.
  if (first == "plugin-worker") {
    execRuntime(memory, words);
  }

  const auto family = parseFamily(first);
  if (!family) {
    return runWindowCommand(memory, words, false);
  }

  return runFamily(memory, *family, words);
}

}
}

auto main(int argc, char **argv) -> int {
  using namespace telar::runtime;

  const std::span<char *const> words = std::span<char *const>{argv, static_cast<std::size_t>(argc)}.subspan(argc > 0 ? 1 : 0);

  try {
    return cli::run(words);
  } catch (const std::invalid_argument &error) {
    const auto reference = cli::helpReference(words);
    std::fprintf(stderr, "telar: %s; see `%s`\n", error.what(), reference.c_str());
  } catch (const cli::CommandError &error) {
    std::fprintf(stderr, "error: %s\n", error.what());
  } catch (const SystemError &error) {
    std::fprintf(stderr, "telar: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar: %s\n", error.what());
  }

  return 1;
}
