#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.testing;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  namespace {

    ds::String<SystemAllocator> escaped(SystemAllocator& memory, std::string_view text, JsonEscapes escapes) {
      ds::String<SystemAllocator> output{memory};

      appendJsonText(output, text, escapes);
      return output;
    }

  }

  // Expected strings of the standard and control JSON escapes for the same
  // bytes.
  void escapes() {
    SystemAllocator memory;
    constexpr std::string_view input{"a\"b\\c\n\r\t\b\f\x01\x1f\x7f\xc3\xa9", 15};

    check(escaped(memory, input, JsonEscapes::standard) == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x7f\xc3\xa9\"");
    check(escaped(memory, input, JsonEscapes::control) == "\"a\\\"b\\\\c\\n\\r\\t\\u0008\\u000c\\u0001\\u001f\\u007f\xc3\xa9\"");
    check(escaped(memory, "", JsonEscapes::control) == "\"\"");
  }

  // A \u escape of a character outside ASCII, as agents send CJK text, unescapes to its
  // UTF-8 bytes beside the other escapes.
  void unescapesCodepoints() {
    SystemAllocator memory;
    ds::String<SystemAllocator> text{memory};

    JsonValue::parse(R"("\u4e2d\u00e9\r\/")").string(text);
    check(text == "\xe4\xb8\xad\xc3\xa9\r/");
  }

  // A field the object does not hold reads as absent, wherever the lookup stops: optional
  // fields are read this way. Looking a field up in anything but an object is an error.
  void missingFieldsAreAbsent() {
    check(!JsonValue::parse(R"({"a":1,"b":2})").field("c").hasValue());
    check(!JsonValue::parse("{}").field("a").hasValue());
    check(JsonValue::parse(R"({"a":1,"b":2})").field("b").hasValue());

    bool refused = false;

    try {
      static_cast<void>(JsonValue::parse("[1]").field("a"));
    } catch (const JsonError&) {
      refused = true;
    }

    check(refused);
  }

  const telar::testing::Case case_escapes{"json_text.escapes", escapes};
  const telar::testing::Case case_unescapes{"json_text.unescapes_codepoints", unescapesCodepoints};
  const telar::testing::Case case_missing_fields{"json_text.missing_fields_are_absent", missingFieldsAreAbsent};

}
