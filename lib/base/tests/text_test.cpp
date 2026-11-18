#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.text;
import telar.base.text.utf8;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  // Text cut to a capacity keeps whole characters, so what is cut still passes the wire's
  // UTF-8 validation.
  void utf8PrefixKeepsWholeCharacters() {
    check(utf8Prefix("a\xc3\xa9", 2) == "a");
    check(utf8Prefix("\xf0\x9f\x98\x80x", 3).empty());
    check(utf8Prefix("abc", 10) == "abc");
    check(utf8Prefix("\xc3\xa9", 0).empty());
  }

  std::optional<std::string> decoded(std::optional<std::size_t> length, const std::array<std::uint8_t, 8>& bytes) {
    if (!length) {
      return std::nullopt;
    }

    return std::string{reinterpret_cast<const char*>(bytes.data()), *length};
  }

  template <base64::Padding Rule>
  std::optional<std::string> decode(std::string_view encoded) {
    std::array<std::uint8_t, 8> bytes{};

    return decoded(base64::decode<Rule>(encoded, bytes), bytes);
  }

  // OSC 52 and the document sequence may leave out the padding, a required rule accepts
  // only padded groups, and the canonical rule also refuses spare bits in the last one.
  void base64PaddingRules() {
    using enum base64::Padding;

    check(decode<optional>("YQ") == "a");
    check(decode<optional>("YQ==") == "a");
    check(!decode<optional>("Y").has_value());
    check(!decode<required>("YQ").has_value());
    check(decode<required>("YR==") == "a");
    check(!decode<canonical>("YR==").has_value());
    check(decode<canonical>("YQ==") == "a");
  }

  const telar::testing::Case case_utf8_prefix{"text.utf8_prefix_keeps_whole_characters", utf8PrefixKeepsWholeCharacters};
  const telar::testing::Case case_base64_padding{"text.base64_padding_rules", base64PaddingRules};

}
