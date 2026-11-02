#pragma once

#include <span>
#include <string>
#include <string_view>
#include <vector>

// The user's login shell, the way lib/pty/login_shell.zig runs it.
namespace telar::gui::platform::login_shell {
// SHELL when the session names one, else the account's shell, else /bin/sh.
std::string path();

// The line a shell runs to exec the command given as its positional parameters, or null for a
// shell whose flags telar does not know.
const char *script(std::string_view shell);

// What a new pane runs: the login shell as an interactive login shell when telar knows its
// flags, else the shell alone. The arguments borrow from this object.
class Command final {
public:
  Command();
  Command(const Command &) = delete;
  Command &operator=(const Command &) = delete;

  std::span<const std::string_view> arguments() const;

private:
  std::string shell_;
  std::vector<std::string> storage_;
  std::vector<std::string_view> arguments_;
};
}
