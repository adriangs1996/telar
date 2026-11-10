export module telar.runtime.shell_integration.token;

import std;
export import telar.client.protocol;
import telar.platform.primitives;

export namespace telar::runtime {

// The secret telar's shell integration signs its OSC 133 marks with. Each pane gets its own,
// in its shell's environment only, so a program that prints a mark cannot sign it.
class ShellToken {
public:
  static constexpr std::size_t length = 32;

  inline static ShellToken generate() noexcept {
    std::array<unsigned char, length / 2> random;
    randomBytes(random.data(), random.size());
    constexpr std::string_view digits = "0123456789abcdef";
    ShellToken token;
    for (std::size_t index = 0; index < random.size(); ++index) {
      token.text_[2 * index] = digits[random[index] >> 4];
      token.text_[2 * index + 1] = digits[random[index] & 0x0f];
    }
    return token;
  }

  // A token another shell chose, as 32 lowercase hexadecimal digits.
  inline static std::optional<ShellToken> parse(std::string_view text) noexcept {
    if (text.size() != length || !std::ranges::all_of(text, [](char digit) { return (digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f'); })) {
      return std::nullopt;
    }
    ShellToken token;
    std::ranges::copy(text, token.text_.begin());
    return token;
  }

  inline std::string_view text() const noexcept {
    return {text_.data(), text_.size()};
  }

  // Compares in constant time, so the time a forged mark takes does not reveal the token.
  inline bool signs(std::string_view candidate) const noexcept {
    if (candidate.size() != length) {
      return false;
    }

    unsigned difference = 0;
    for (std::size_t index = 0; index < length; ++index) {
      difference |= static_cast<unsigned char>(text_[index]) ^ static_cast<unsigned char>(candidate[index]);
    }
    return difference == 0;
  }

private:
  std::array<char, length> text_{};
};

// A shell telar integrated with, and the token its marks carry.
struct ShellLaunch {
  IntegratedShell shell;
  ShellToken token;
};

}
