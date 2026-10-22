#include "login_shell.hpp"
#include <array>
#include <cstdlib>
#include <pwd.h>
#include <unistd.h>

namespace login_shell {
  std::string path() {
    if (const char *shell = std::getenv("SHELL"); shell && *shell) {
      return shell;
    }

    if (const auto *entry = ::getpwuid(::getuid()); entry && entry->pw_shell && *entry->pw_shell) {
      return entry->pw_shell;
    }

    return "/bin/sh";
  }

  // Mirrors `script` in lib/pty/login_shell.zig.
  const char *script(std::string_view shell) {
    const auto name = shell.substr(shell.find_last_of('/') + 1);

    if (name == "bash" || name == "zsh" || name == "ksh") {
      return "exec -- \"$0\" \"$@\"";
    }

    if (name == "sh" || name == "dash") {
      return "exec \"$0\" \"$@\"";
    }

    if (name == "fish") {
      return "exec $argv";
    }

    return nullptr;
  }

  Command::Command()
      : shell_(path()) {
    // The runtime searches its own PATH for a relative program, which need not be the user's.
    if (shell_.front() != '/') {
      shell_ = "/bin/sh";
    }

#if defined(__linux__)
    // The runtime may predate this compositor. Pass display discovery to new
    // panes as argv, without shell interpolation or replacing its environment.
    if (const char *desktop = std::getenv("XDG_CURRENT_DESKTOP");
        desktop && std::string_view(desktop) == "Telar") {
      storage_.emplace_back("/usr/bin/env");
      constexpr std::array names{"WAYLAND_DISPLAY",
                                 "DISPLAY",
                                 "XDG_RUNTIME_DIR",
                                 "XDG_SESSION_TYPE",
                                 "XDG_CURRENT_DESKTOP",
                                 "DBUS_SESSION_BUS_ADDRESS"};
      for (const auto *name : names) {
        if (const auto *value = std::getenv(name)) {
          storage_.push_back(std::string(name) + "=" + value);
        }
      }
    }
#endif
    storage_.push_back(shell_);
    if (script(shell_)) {
      storage_.push_back("-l");
      storage_.push_back("-i");
    }
    for (const auto &argument : storage_) {
      arguments_.push_back(argument);
    }
  }

  std::span<const std::string_view> Command::arguments() const {
    return arguments_;
  }
} // namespace login_shell
