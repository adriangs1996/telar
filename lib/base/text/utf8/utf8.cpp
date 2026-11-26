module telar.base.text.utf8;

import std;

namespace telar {

  EncodingError::EncodingError(const char* message) noexcept
      : message_{message} {}

  const char* EncodingError::what() const noexcept {
    return message_;
  }

  Utf8Validation inspectUtf8(std::string_view value) noexcept {
    constexpr std::uint8_t ascii_end = 0x80;
    std::size_t index = 0;

    while (index < value.size()) {
      const auto lead = static_cast<std::uint8_t>(value[index]);
      if (lead < ascii_end) {
        ++index;
        continue;
      }

      const auto length = utf8::sequenceLength(lead);
      if (length == 0 || length > value.size() - index) {
        return Utf8Validation::invalid_leading;
      }

      for (std::size_t offset = 1; offset < length; ++offset) {
        if (!utf8::isContinuation(static_cast<std::uint8_t>(value[index + offset]))) {
          return Utf8Validation::invalid_continuation;
        }
      }

      if (!utf8::scalarSecond(lead, static_cast<std::uint8_t>(value[index + 1]))) {
        return Utf8Validation::invalid_scalar;
      }

      index += length;
    }

    return Utf8Validation::valid;
  }

  void validateUtf8(std::string_view value) {
    switch (inspectUtf8(value)) {
    case Utf8Validation::valid:
      return;
    case Utf8Validation::invalid_leading:
      throw EncodingError{"Invalid UTF-8"};
    case Utf8Validation::invalid_continuation:
      throw EncodingError{"Invalid UTF-8 continuation"};
    case Utf8Validation::invalid_scalar:
      throw EncodingError{"Invalid UTF-8 scalar"};
    }
  }

}

namespace telar::runtime {

  std::string_view utf8Prefix(std::string_view text, std::size_t capacity) noexcept {
    auto length = text.size() < capacity ? text.size() : capacity;

    while (length != 0 && length < text.size() && utf8::isContinuation(static_cast<std::uint8_t>(text[length]))) {
      --length;
    }

    text.remove_suffix(text.size() - length);
    return text;
  }

}
