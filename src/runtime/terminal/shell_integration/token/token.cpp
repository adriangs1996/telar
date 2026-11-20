module telar.runtime.terminal.shell_integration.token;

import std;
import telar.platform.primitives;
import telar.base.text;
import telar.base.ds;

namespace telar::runtime {

  ShellToken ShellToken::generate() noexcept {
    ds::Array<unsigned char, length / 2> random{};

    randomBytes(random.dataMut(), random.size());
    ShellToken token;

    static_cast<void>(encodeLowerHex(random.view(), token.text_.viewMut()));
    return token;
  }

  ds::Option<ShellToken> ShellToken::parse(std::string_view text) noexcept {
    if (text.size() != length || !std::ranges::all_of(text, [](char digit) {
          return (digit >= '0' && digit <= '9') || (digit >= 'a' && digit <= 'f');
        })) {
      return ds::none;
    }

    ShellToken token;

    std::ranges::copy(text, token.text_.viewMut().begin());
    return token;
  }

  std::string_view ShellToken::text() const noexcept {
    return {text_.data(), text_.size()};
  }

  bool ShellToken::signs(std::string_view candidate) const noexcept {
    return constantTimeEqual({text_.data(), text_.size()}, candidate);
  }

}
