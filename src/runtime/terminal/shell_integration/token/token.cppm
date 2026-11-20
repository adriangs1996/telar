export module telar.runtime.terminal.shell_integration.token;

import std;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::runtime {

  // The secret telar's shell integration signs its OSC 133 marks with. Each pane gets its own,
  // in its shell's environment only, so a program that prints a mark cannot sign it.
  class ShellToken {
  public:
    static constexpr std::size_t length = 32;

    static ShellToken generate() noexcept;

    // A token another shell chose, as 32 lowercase hexadecimal digits.
    static ds::Option<ShellToken> parse(std::string_view text) noexcept;

    [[nodiscard]] std::string_view text() const noexcept;

    // Compares in constant time, so the time a forged mark takes does not reveal the token.
    [[nodiscard]] bool signs(std::string_view candidate) const noexcept;

  private:
    ds::Array<char, length> text_{};
  };

  // A shell telar integrated with, and the token its marks carry.
  struct ShellLaunch {
    IntegratedShell shell = IntegratedShell::none;
    ShellToken token;
  };

}
