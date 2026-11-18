export module telar.gui.foundation.system:login_shell;

import std;

import telar.sys.posix;
import telar.tbc;
import telar.base.ds;
import telar.base.memory.containers;

// Interface: platform/external_links.cppm
export {
  namespace telar::gui::inline foundation::inline system {

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
// Qt declares it; the signature below only names it.
extern "C++" class QByteArray;

export {
  namespace telar::gui::inline foundation::inline system {

    QByteArray hostName();

  }
}

// Interface: platform/login_shell.cppm
export {
  // What a new pane runs, from telar-platform's loginShell and loginShellScript.
  namespace telar::gui::inline foundation::inline system::login_shell {
    // What a new pane runs: the login shell as an interactive login shell when telar knows its
    // flags, else the shell alone. The arguments borrow from this object.
    class Command final {
    public:
      Command();
      ~Command() = default;
      Command(const Command&) = delete;
      Command& operator=(const Command&) = delete;
      Command(Command&&) = delete;
      Command& operator=(Command&&) = delete;

      [[nodiscard]] std::span<const std::string_view> arguments() const;

    private:
      runtime::FixedText<PATH_MAX> shell_;
      // The shell, then its flags, which are literals; the shell's view borrows shell_.
      tbc::view<ds::Array<std::string_view, 3>, tbc::lt::self> arguments_;
      std::size_t count_ = 0;
    };
  }
}
