#include "agent.hpp"
#include "api_schema.hpp"
#include "diagnostics.hpp"
#include "execution.hpp"
#include "file_transfer.hpp"
#include "help.hpp"
#include "history.hpp"
#include "hook.hpp"
#include "integration.hpp"
#include "integration_assets.hpp"
#include "pane.hpp"
#include "plugin.hpp"
#include "project_setup.hpp"
#include "proxy_trust.hpp"
#include "repository_prepare.hpp"
#include "runtime_observer.hpp"
#include "server.hpp"
#include "tab.hpp"
#include "workspace.hpp"
#include "worktree.hpp"
#include "window.hpp"
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
  case Family::pane:
    return runPane(memory, pane_agents::parsePane(options));
  case Family::agent:
    return runAgent(memory, pane_agents::parseAgent(options));
  case Family::exec:
    return execution::run(memory, ExecutionOptions::parse(options));
  case Family::file:
    return file_transfer::run(file_transfer::Options::parse(options));
  case Family::runtime:
    return runRuntime(memory, RuntimeOptions::parse(options));
  case Family::diagnostics:
    return diagnostics::run(memory, DiagnosticsOptions::parse(options));
  case Family::api:
    return api::run(options);
  case Family::history:
    return history::run(memory, HistoryOptions::parse(options));
  case Family::project:
    return project_setup::run(memory, project_setup::Options::parse(options));
  case Family::repository:
    return repository::run(memory, RepositoryOptions::parse(options));
  case Family::hook:
    return runHook(memory, HookOptions::parse(options), ProcessEnvironment{});
  case Family::integration:
    return runIntegration(memory, IntegrationOptions::parse(options));
  case Family::client:
  case Family::sidebar:
  case Family::workspace_list:
  case Family::layout:
  case Family::notification:
  case Family::command:
  case Family::config:
    return runWindow(family, options);
  case Family::plugin:
    if (!options.empty() && (std::string_view{options[0]} == "list" || std::string_view{options[0]} == "get" || std::string_view{options[0]} == "enable" || std::string_view{options[0]} == "disable" || std::string_view{options[0]} == "run")) {
      return runWindow(family, options);
    }

    runPlugin(memory, PluginOptions::parse(options), ProcessEnvironment{});
    return 0;
  case Family::proxy: {
    if (!options.empty() && std::string_view{options.front()} == "watch") {
      auto parsed = RuntimeOptions::parse(options);
      parsed.proxy_only = true;
      return runRuntime(memory, parsed);
    }

    SynchronizedAllocator synchronized{memory};
    return runProxyTrust(synchronized, ProxyTrustOptions::parse(options), ProcessEnvironment{});
  }
  case Family::server:
    runServer(memory, words);
    return 0;
  case Family::workspace:
    if (!options.empty() && std::string_view{options.front()} == "select") {
      return sessions::routed(memory, sessions::RoutedOptions::parse("workspace", options));
    }
    {
      const auto parsed = sessions::WorkspaceOptions::parse(options);
      if (parsed.worktree) {
        sessions::WorktreeOptions worktree;
        worktree.action = sessions::WorktreeOptions::Action::create;
        worktree.branch = parsed.worktree;
        worktree.title = parsed.name;
        worktree.directory = parsed.directory;
        worktree.socket = parsed.socket;
        worktree.json = parsed.json;
        return sessions::worktree(memory, worktree);
      }
      return sessions::workspace(memory, parsed);
    }
  case Family::tab:
    if (!options.empty()) {
      const std::string_view verb = options.front();
      const bool background = std::ranges::any_of(options.subspan(1), [](const char *word) { return std::string_view{word} == "--background"; });
      if (verb == "select" || verb == "next" || verb == "previous" || (verb == "create" && !background)) {
        return sessions::routed(memory, sessions::RoutedOptions::parse("tab", options));
      }
    }
    return sessions::tab(memory, sessions::TabOptions::parse(options));
  case Family::worktree:
    return sessions::worktree(memory, sessions::WorktreeOptions::parse(options));
  default:
    return unavailable(std::string{"telar "} + std::string{familyName(family)});
  }
}

int run(std::span<char *const> words) {
  if (const auto topic = findHelp(words)) {
    const auto text = helpText(*topic).value_or(helpText({}).value_or(""));
    std::fwrite(text.data(), 1, text.size(), stdout);
    return 0;
  }

  if (words.empty()) {
    return unavailable("opening a window");
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
    return unavailable(first.starts_with("--") ? "telar " + std::string{first} : std::string{"running a command in a window"});
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
  } catch (const SystemError &error) {
    std::fprintf(stderr, "telar: %s: %s\n", error.what(), std::strerror(error.code()));
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar: %s\n", error.what());
  }

  return 1;
}
