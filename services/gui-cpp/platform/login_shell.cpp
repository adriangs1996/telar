module;

#include <cstdlib>
#include <pwd.h>
#include <unistd.h>

module telar.gui.platform.login_shell;

import std;



namespace telar::gui::platform::login_shell {
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
}
