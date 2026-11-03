#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_lua/value.hpp"

namespace telar::runtime::config {

inline void optionalChoice(const lua::Value &value, std::initializer_list<std::string_view> choices) {
  if (!value.present()) {
    return;
  }

  const auto text = value.string();
  if (std::find(choices.begin(), choices.end(), text) == choices.end()) {
    value.fail("is not a supported value");
  }
}

inline void optionalWholeNumber(const lua::Value &value, double minimum, double maximum) {
  const auto number = value.boundedNumber(minimum, minimum, maximum);
  if (std::trunc(number) != number) {
    value.fail("must be a whole number");
  }
}

inline void optionalUtf8Text(const lua::Value &value, std::size_t maximum_bytes) {
  if (!value.present()) {
    return;
  }

  const auto text = value.string();
  validateUtf8(text);
  if (text.size() > maximum_bytes || text.contains('\0')) {
    value.fail("exceeds its text bounds or contains NUL");
  }
}

}
