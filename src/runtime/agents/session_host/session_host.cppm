module;

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.agents.session_host;

import std;

import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.config;
import telar.platform;

// Interface: agents/session_host.cppm
export {
  namespace telar::runtime {

    enum class SessionHost {
      unknown,
      pane,
      shared_server,
    };

    inline constexpr std::string_view codex_pane_argument = "--no-daemon";
    inline constexpr std::array codex_batch_arguments{
        "exec",
        "e",
        "review",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "plugin",
        "app-server",
        "remote-control",
        "app",
        "completion",
        "update",
        "doctor",
        "sandbox",
        "debug",
        "apply",
        "a",
        "queue",
        "archive",
        "delete",
        "migrate-rollouts",
        "unarchive",
        "cloud",
        "exec-server",
        "features",
        "agents",
        "help",
        "--help",
        "-h",
        "--version",
        "-V"
    };

    inline bool isCodexBatchArgument(std::string_view argument) noexcept {
      return std::ranges::any_of(codex_batch_arguments, [argument](std::string_view candidate) {
        return argument == candidate;
      });
    }

  }
}

// Interface: agents/hook_settings.cppm
export {
  namespace telar::runtime {

    // Whether Codex's hook settings, where the CLI installs them, run `telar hook codex`.
    inline bool codexHooksInstalled(const char* override_directory, std::string_view home) noexcept {
      const auto provider = config::IntegrationProvider::describe(AgentProvider::codex);
      std::array<char, PATH_MAX> path;
      int length = 0;

      if (override_directory != nullptr && *override_directory != '\0') {
        length = std::snprintf(path.data(), path.size(), "%s%.*s/%.*s", override_directory, static_cast<int>(provider.environment_suffix.size()), provider.environment_suffix.data(), static_cast<int>(provider.file.size()), provider.file.data());
      } else if (!home.empty()) {
        length = std::snprintf(path.data(), path.size(), "%.*s/%.*s/%.*s", static_cast<int>(home.size()), home.data(), static_cast<int>(provider.home_directory.size()), provider.home_directory.data(), static_cast<int>(provider.file.size()), provider.file.data());
      } else {
        return false;
      }

      if (length < 0 || static_cast<std::size_t>(length) >= path.size()) {
        return false;
      }

      FileDescriptor file{::open(path.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
      struct stat metadata;
      if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
        return false;
      }

      constexpr std::size_t maximum_settings_bytes = 32 * 1024;
      std::array<char, maximum_settings_bytes> bytes;
      const auto count = ::read(file.get(), bytes.data(), bytes.size());

      return count > 0 && std::string_view{bytes.data(), static_cast<std::size_t>(count)}.contains(" hook codex");
    }

    inline bool hooksInstalled(AgentProvider provider, SessionHost host) noexcept {
      return provider == AgentProvider::codex && host == SessionHost::shared_server && codexHooksInstalled(std::getenv(config::IntegrationProvider::describe(AgentProvider::codex).environment), processHome());
    }

  }
}
