#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string nested(std::size_t depth) {
    return std::string(depth, '[') + "0" + std::string(depth, ']');
  }

  template <typename Operation>
  bool jsonRefused(Operation&& operation) {
    try {
      operation();
    } catch (const JsonError&) {
      return true;
    }

    return false;
  }

  // The parser recurses once per nesting level, so the depth bound is what keeps a hostile
  // hook payload from exhausting the stack.
  void testJsonDepthLimit() {
    constexpr unsigned maximum_depth = 4;

    check(!jsonRefused([] {
      static_cast<void>(JsonValue::parse(nested(maximum_depth), maximum_depth));
    }));

    check(jsonRefused([] {
      static_cast<void>(JsonValue::parse(nested(maximum_depth + 1), maximum_depth));
    }));

    const auto deep = nested(100'000);
    SystemAllocator memory;

    check(jsonRefused([&] {
      static_cast<void>(JsonValue::parse(deep));
    }));

    check(jsonRefused([&] {
      static_cast<void>(JsonNode<SystemAllocator>::parse(memory, deep));
    }));
  }

  // The text in an exactly sized heap block, so reading one byte past it is a heap overflow
  // the sanitize preset reports.
  bool stringRefused(std::string_view text) {
    const auto bytes = std::make_unique<char[]>(text.size());

    std::memcpy(bytes.get(), text.data(), text.size());
    return jsonRefused([&] {
      static_cast<void>(JsonValue::parse({bytes.get(), text.size()}));
    });
  }

  // A string token is refused when it carries a raw control byte, ends inside an escape, or
  // has a \u escape of fewer than four hexadecimal digits; a high surrogate decodes only
  // with a low one after it.
  void testJsonRejectsMalformedStrings() {
    check(stringRefused("\"a\001b\""));
    check(stringRefused("\"\\"));
    check(stringRefused("\"\\u12\""));
    check(stringRefused("\"\\u12"));
    check(stringRefused("\"\\u12zz\""));
    check(!stringRefused("\"\\u0041\""));

    SystemAllocator memory;
    String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
    const auto unpaired = JsonValue::parse(R"("\ud800\u0041")");

    check(jsonRefused([&] {
      unpaired.string(text);
    }));

    const auto paired = JsonValue::parse(R"("\ud83d\ude00")");

    paired.string(text);
    check(text == "\xf0\x9f\x98\x80");
  }

  // Overlong forms, surrogates and scalars past U+10FFFF are not UTF-8, so neither the wire,
  // a configuration nor a record on disk accepts them.
  void testUtf8RejectsIllFormed() {
    for (const std::string_view bytes : {"\xc0\x80", "\xf5\x80\x80\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\xe2\x28\xa1"}) {
      bool thrown = false;

      check(inspectUtf8(bytes) != Utf8Validation::valid);
      try {
        validateUtf8(bytes);
      } catch (const EncodingError&) {
        thrown = true;
      }

      check(thrown);
    }

    for (const std::string_view bytes : {"\xed\x9f\xbf", "\xee\x80\x80", "\xf4\x8f\xbf\xbf"}) {
      check(inspectUtf8(bytes) == Utf8Validation::valid);
      validateUtf8(bytes);
    }
  }

  const telar::testing::Case case_json_depth{"json.depth_limit", testJsonDepthLimit};
  const telar::testing::Case case_json_strings{"json.rejects_malformed_strings", testJsonRejectsMalformedStrings};
  const telar::testing::Case case_utf8_ill_formed{"utf8.rejects_ill_formed", testUtf8RejectsIllFormed};

}
