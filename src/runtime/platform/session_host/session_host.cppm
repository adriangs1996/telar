export module telar.runtime.platform.session_host;

import std;

import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.config.core;
import telar.platform.paths;

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

    bool isCodexBatchArgument(std::string_view argument) noexcept;

  }
}

// Interface: agents/hook_settings.cppm
export {
  namespace telar::runtime {

    // Whether Codex's hook settings, where the CLI installs them, run `telar hook codex`.
    bool codexHooksInstalled(const char* override_directory, std::string_view home) noexcept;

    bool hooksInstalled(AgentProvider provider, SessionHost host) noexcept;

  }
}
