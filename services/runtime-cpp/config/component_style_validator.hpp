#pragma once

#include "ui_value_constraints.hpp"

namespace telar::runtime::config {

class ComponentStyleValidator {
public:
  static void validate(const lua::Value &component) {
    for (const auto *name : {"fg", "bg"}) {
      const auto value = component.field(name);
      if (value.present()) {
        color(value);
      }
    }
    for (const auto *name : {"bold", "italic", "faint", "underline", "strikethrough"}) {
      component.field(name).boolean(false);
    }
  }

private:
  static void color(const lua::Value &value) {
    if (const auto index = value.asInteger()) {
      if (*index < 0 || *index > 255) {
        value.fail("is outside the color index range");
      }
      return;
    }

    constexpr std::string_view names[]{"default", "accent", "panel_bg", "surface0", "surface1", "surface_dim", "overlay0", "overlay1", "text", "subtext0", "mauve", "green", "yellow", "red", "blue", "teal", "peach"};
    const auto text = value.string();
    if (std::ranges::any_of(names, [text](std::string_view name) { return equalUiName(text, name); })) {
      return;
    }
    if (text.size() == 7 && text.front() == '#' && hexadecimal(text.substr(1))) {
      return;
    }
    value.fail("is not a supported color");
  }

  static bool hexadecimal(std::string_view digits) noexcept {
    const bool negative = digits.front() == '-';
    if (negative || digits.front() == '+') {
      digits.remove_prefix(1);
    }
    if (digits.empty() || digits.front() == '_' || digits.back() == '_') {
      return false;
    }

    unsigned value = 0;
    for (const auto byte : digits) {
      if (byte == '_') {
        continue;
      }
      const auto lower = asciiLower(byte);
      if (byte >= '0' && byte <= '9') {
        value = value * 16 + static_cast<unsigned>(byte - '0');
      } else if (lower >= 'a' && lower <= 'f') {
        value = value * 16 + static_cast<unsigned>(lower - 'a' + 10);
      } else {
        return false;
      }
    }
    return !negative || value == 0;
  }
};

}
