#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.cli.tests.check;
import telar.cli.output;

using namespace telar;
using namespace telar::runtime;

namespace {

  String<SystemAllocator> escaped(SystemAllocator& memory, std::string_view text, JsonEscapes escapes) {
    String<SystemAllocator> output{AllocatorRef<char, SystemAllocator>{memory}};

    appendJsonText(output, text, escapes);
    return output;
  }

}

// Expected strings of the standard and control JSON escapes for the same
// bytes.
int main() {
  SystemAllocator memory;
  constexpr std::string_view input{"a\"b\\c\n\r\t\b\f\x01\x1f\x7f\xc3\xa9", 15};

  check(escaped(memory, input, JsonEscapes::standard) == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x7f\xc3\xa9\"");
  check(escaped(memory, input, JsonEscapes::control) == "\"a\\\"b\\\\c\\n\\r\\t\\u0008\\u000c\\u0001\\u001f\\u007f\xc3\xa9\"");
  check(escaped(memory, "", JsonEscapes::control) == "\"\"");
  return 0;
}
