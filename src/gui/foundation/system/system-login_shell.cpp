module;

module telar.gui.foundation.system;

import std;
import telar.platform.process;

namespace telar::gui::inline foundation::inline system::login_shell {
  Command::Command()
      : shell_(runtime::loginShell()) {
    arguments_.atMut(count_++) = shell_.view();
    if (!runtime::loginShellScript(shell_.view()).empty()) {
      arguments_.atMut(count_++) = "-l";
      arguments_.atMut(count_++) = "-i";
    }
  }

  std::span<const std::string_view> Command::arguments() const {
    return arguments_.view().first(count_);
  }
}
