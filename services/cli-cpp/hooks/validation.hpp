#pragma once

#include "object.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
void validateUnicodeEscapes(Memory &memory, std::string_view input) {
  if (!input.contains("\\u")) {
    return;
  }

  String<Memory> decoded{AllocatorRef<char, Memory>{memory}};
  std::optional<std::size_t> start;
  for (std::size_t index = 0; index < input.size(); ++index) {
    if (start && input[index] == '\\') {
      ++index;
    } else if (input[index] == '"') {
      if (start) {
        const auto token = input.substr(*start, index - *start + 1);
        if (token.contains("\\u")) {
          JsonValue{token}.string(decoded);
        }

        start.reset();
      } else {
        start = index;
      }
    }
  }
}

template <Allocator Memory>
void validateDynamicValue(Memory &memory, JsonValue value) {
  if (value.encoded().starts_with('{')) {
    Object fields{memory, value};
    fields.requireUnique();
    fields.eachValue([&](JsonValue child) { validateDynamicValue(memory, child); });
  } else if (value.encoded().starts_with('[')) {
    value.eachElement([&](JsonValue child) { validateDynamicValue(memory, child); });
  }
}

}
