module;

module telar.gui.platform.login_shell;

import std;
import telar.platform.process;

namespace telar::gui::platform::login_shell {
  Command::Command()
      : shell_(runtime::loginShell().view()) {
    storage_.push_back(shell_);
    if (!runtime::loginShellScript(shell_).empty()) {
      storage_.push_back("-l");
      storage_.push_back("-i");
    }

    for (const auto& argument : storage_) {
      arguments_.push_back(argument);
    }
  }

  std::span<const std::string_view> Command::arguments() const {
    return arguments_;
  }
}
