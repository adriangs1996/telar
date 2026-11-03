#pragma once

#include "json_text.hpp"
#include "telar_base/memory/allocator.hpp"
#include <array>
#include <charconv>
#include <cstdio>
#include <string_view>

namespace telar::runtime::cli {

// A command's stdout, built in memory and written once, so a failure halfway
// prints nothing of the result.
template <Allocator Memory>
class Output {
public:
  explicit Output(Memory &memory)
      : data(AllocatorRef<char, Memory>{memory}) {}

  Output &text(std::string_view value) {
    data.append(value);
    return *this;
  }

  template <typename Integer>
  Output &number(Integer value) {
    std::array<char, 32> buffer;
    const auto end = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value).ptr;
    data.append(buffer.data(), end);
    return *this;
  }

  Output &boolean(bool value) {
    return text(value ? "true" : "false");
  }

  Output &json(std::string_view value, JsonEscapes escapes = JsonEscapes::standard) {
    appendJsonText(data, value, escapes);
    return *this;
  }

  void flush() {
    std::fwrite(data.data(), 1, data.size(), stdout);
    std::fflush(stdout);
    data.clear();
  }

  String<Memory> data;
};

}
