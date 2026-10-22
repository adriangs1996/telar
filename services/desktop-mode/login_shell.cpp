#include "login_shell.hpp"
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

    arguments_ = {shell_, "-l", "-i"};
    count_ = script(shell_) ? arguments_.size() : 1;
  }

  std::span<const std::string_view> Command::arguments() const {
    return std::span(arguments_).first(count_);
  }
} // namespace login_shell
