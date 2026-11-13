module;
#include "tbc/view.hpp"




export module telar.gui.platform.login_shell;

import std;


// Interface: platform/external_links.cppm
export {
namespace telar::gui::platform {

struct AppleExternalLinks {
  static constexpr std::string_view executable = "/usr/bin/open";
};

struct LinuxExternalLinks {
  static constexpr std::string_view executable = "xdg-open";
};

#ifdef __APPLE__
using NativeExternalLinks = AppleExternalLinks;
#else
using NativeExternalLinks = LinuxExternalLinks;
#endif

}
}

// Interface: platform/host_name.cppm
export {
class QByteArray;

namespace telar::gui::platform {

QByteArray hostName();

}
}

// Interface: platform/login_shell.cppm
export {
// What a new pane runs, from telar-platform's loginShell and loginShellScript.
namespace telar::gui::platform::login_shell {
// What a new pane runs: the login shell as an interactive login shell when telar knows its
// flags, else the shell alone. The arguments borrow from this object.
class Command final {
public:
  Command();
  ~Command() = default;
  Command(const Command &) = delete;
  Command &operator=(const Command &) = delete;
  Command(Command &&) = delete;
  Command &operator=(Command &&) = delete;

  [[nodiscard]] std::span<const std::string_view> arguments() const;

private:
  std::string shell_;
  std::vector<std::string> storage_;
  // The arguments view the strings stored beside them.
  tbc::view<std::vector<std::string_view>, tbc::lt::self> arguments_;
};
}
}

// Interface: platform/managed_directory.cppm
export {
namespace telar::gui::platform {

void prepareManagedDirectory(std::string_view path);

}
}
