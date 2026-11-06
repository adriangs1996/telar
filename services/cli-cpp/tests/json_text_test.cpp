#include "../json_text.hpp"
#include "check.hpp"

using namespace telar;
using namespace telar::runtime;

namespace {

String<SystemAllocator> escaped(SystemAllocator &memory, std::string_view text, cli::JsonEscapes escapes) {
  String<SystemAllocator> output{AllocatorRef<char, SystemAllocator>{memory}};
  cli::appendJsonText(output, text, escapes);
  return output;
}

}

// Expected strings are what Zig 0.16's std.json.Stringify and Telar's
// control.writeJsonString write for the same bytes.
int main() {
  SystemAllocator memory;
  constexpr std::string_view input{"a\"b\\c\n\r\t\b\f\x01\x1f\x7f\xc3\xa9", 15};
  check(escaped(memory, input, cli::JsonEscapes::standard) == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\x7f\xc3\xa9\"");
  check(escaped(memory, input, cli::JsonEscapes::control) == "\"a\\\"b\\\\c\\n\\r\\t\\u0008\\u000c\\u0001\\u001f\\u007f\xc3\xa9\"");
  check(escaped(memory, "", cli::JsonEscapes::control) == "\"\"");
  return 0;
}
