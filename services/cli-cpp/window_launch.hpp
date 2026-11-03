#pragma once

#include "launch_process.hpp"
#include "machine_store.hpp"
#include "server.hpp"
#include "window_options.hpp"
#include <filesystem>
#include <pwd.h>

namespace telar::runtime::cli {

inline std::string guiProgram() {
  const auto directory = std::filesystem::path{ExecutablePath{}.c_str()}.parent_path();
  for (const auto &candidate : {directory / "telar-gui", directory / ".." / ".." / "MacOS" / "telar-gui"}) {
    struct stat state{};
    if (::stat(candidate.c_str(), &state) == 0 && S_ISREG(state.st_mode) && ::access(candidate.c_str(), X_OK) == 0) {
      return candidate.lexically_normal().string();
    }
  }

  return "telar-gui";
}

inline std::string loginShell() {
  if (const auto *shell = std::getenv("SHELL"); shell && *shell) {
    return shell;
  }

  if (const auto *account = ::getpwuid(::getuid()); account && account->pw_shell) {
    return account->pw_shell;
  }

  return "/bin/sh";
}

inline std::optional<std::string_view> shellScript(const std::string &shell) {
  const auto name = std::filesystem::path{shell}.filename().string();
  if (name == "bash" || name == "zsh" || name == "ksh") {
    return R"(exec -- "$0" "$@")";
  }

  if (name == "sh" || name == "dash") {
    return R"(exec "$0" "$@")";
  }

  if (name == "fish") {
    return "exec $argv";
  }

  return std::nullopt;
}

inline void relaunchLogin(std::span<char *const> words) {
  if (std::getenv("TELAR_LOGIN_SHELL")) {
    return;
  }

  const auto shell = loginShell();
  const auto script = shellScript(shell);
  if (!script) {
    return;
  }

  std::vector<std::string> arguments{shell, "-l", "-c", std::string{*script}, ExecutablePath{}.c_str(), "gui"};
  for (const std::string_view word : words) {
    if (word != "--login-shell") {
      arguments.emplace_back(word);
    }
  }

  ::setenv("TELAR_LOGIN_SHELL", "1", 1);
  launch::replace(arguments);
}

template <Allocator Memory>
int openWindow(Memory &memory, const WindowOptions &options) {
#if defined(__APPLE__)
  const bool display = std::getenv("SSH_CONNECTION") == nullptr && std::getenv("SSH_TTY") == nullptr;
#else
  const auto *wayland = std::getenv("WAYLAND_DISPLAY");
  const bool display = wayland && *wayland;
#endif
  if (!display) {
    std::fputs("telar: no display to open a window here (an SSH login, or Linux without WAYLAND_DISPLAY).\n"
               "From a terminal, reach the panes and agents through the CLI:\n"
               "  telar pane read|watch|send-keys, telar agent prompt, telar --machine LABEL COMMAND\n",
               stderr);
    return 1;
  }

  if (options.machine) {
    try {
      const auto profiles = machine::load(memory, machine::profilesPath());
      if (!profiles.find(*options.machine) && machine::localLabel(profiles) != *options.machine) {
        std::fputs("telar gui: no saved machine or local label has that name; see telar machine list\n", stderr);
        return 1;
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "telar gui: %s\n", error.what());
      return 1;
    }
  }

  ServerOptions server;
  server.config = options.config ? std::string_view{*options.config} : std::string_view{};
  server.no_config = options.no_config;
  server.profile = options.profile ? std::string_view{*options.profile} : std::string_view{};
  server.fresh = options.fresh;
  const RuntimePaths paths{memory, server, ProcessEnvironment{}};
  std::optional<RuntimeConnection> connection;
  if (connectExisting(connection, paths.socket.c_str()) && options.fresh) {
    std::fprintf(stderr, "telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\n");
    throw CommandError{"RuntimeAlreadyRunning"};
  }

  if (!connection) {
    paths.prepareSocket();
    const auto child = launchDaemon(memory, server, paths, ExecutablePath{runtime_program});
    constexpr auto start_timeout = std::chrono::seconds{10};
    constexpr auto retry_interval = std::chrono::milliseconds{10};
    const auto deadline = std::chrono::steady_clock::now() + start_timeout;
    while (!connectExisting(connection, paths.socket.c_str())) {
      int status = 0;
      if (::waitpid(child, &status, WNOHANG) == child || std::chrono::steady_clock::now() >= deadline) {
        throw CommandError{"RuntimeUnavailable"};
      }

      std::this_thread::sleep_for(retry_interval);
    }
  }

  connection.reset();
  std::vector<std::string> arguments{guiProgram(), "--socket", std::string{paths.socket}, "--cwd", std::filesystem::current_path().string()};
  for (const auto &[flag, value] : std::array<std::pair<std::string_view, const std::optional<std::string> *>, 5>{{{"--config", &options.config}, {"--profile", &options.profile}, {"--theme", &options.theme}, {"--remote", &options.remote}, {"--machine", &options.machine}}}) {
    if (*value) {
      arguments.emplace_back(flag);
      arguments.push_back(**value);
    }
  }

  if (options.no_config) {
    arguments.emplace_back("--no-config");
  }

  if (options.fresh) {
    arguments.emplace_back("--fresh");
  }

  if (!options.command.empty()) {
    arguments.emplace_back("--");
    arguments.insert(arguments.end(), options.command.begin(), options.command.end());
  }

  launch::replace(arguments);
}

}
