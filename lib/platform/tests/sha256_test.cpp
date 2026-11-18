#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.platform.sha256;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  std::string hex(std::span<const std::uint8_t> digest) {
    constexpr std::string_view digits = "0123456789abcdef";
    std::string text;

    for (const auto byte : digest) {
      text += digits[byte >> 4];
      text += digits[byte & 0xf];
    }

    return text;
  }

  // The Cursor hook names a chat directory by the MD5 of its workspace, so md5 is the standard
  // digest, whole.
  void testMd5KnownVectors() {
    const auto empty = md5("");
    const auto abc = md5("abc");

    check(empty.has_value() && hex(*empty) == "d41d8cd98f00b204e9800998ecf8427e");
    check(abc.has_value() && hex(*abc) == "900150983cd24fb0d6963f7d28e17f72");
  }

  const telar::testing::Case case_md5{"sha256.md5_known_vectors", testMd5KnownVectors};

}
