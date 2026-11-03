#pragma once

#include "pick_items.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_config/ui_value_constraints.hpp"
#include "telar_lua/value.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <cstddef>
#include <lua.h>
#include <optional>
#include <string_view>
#include <system_error>

namespace telar::gui::components {

class PickItemsReader {
public:
  static void read(const runtime::lua::Value &value, PickItems &output, runtime::config::LimitNotices &limits) {
    PickItems next;
    const auto count = value.arraySize();
    for (std::size_t index = 0; index < count; ++index) {
      item(value.element(static_cast<lua_Integer>(index) + 1), next);
    }

    output = next;
    output.report(limits);
  }

  static void lines(std::string_view text, PickItems &output, runtime::config::LimitNotices &limits) {
    PickItems next;
    std::array<char, PickItems::maximum_label_bytes> label{};
    while (!text.empty()) {
      const auto newline = text.find('\n');
      const auto line = text.substr(0, newline);
      text = newline == std::string_view::npos ? std::string_view{} : text.substr(newline + 1);
      constexpr std::string_view blanks = " \t\r";
      const auto first = line.find_first_not_of(blanks);
      if (first == std::string_view::npos) {
        continue;
      }

      const auto option = line.substr(first, line.find_last_not_of(blanks) - first + 1);
      const auto shown = runtime::utf8Prefix(option, label.size());
      std::ranges::transform(shown, label.begin(), [](char byte) { return byte == '\t' ? ' ' : byte; });
      PickInput input;
      input.label = {label.data(), shown.size()};
      input.value = option;
      next.keep(input);
    }

    output = next;
    output.report(limits);
  }

private:
  static void item(const runtime::lua::Value &value, PickItems &items) {
    PickInput input;
    if (value.is(LUA_TSTRING)) {
      input.label = value.string();
      items.keep(input);

      return;
    }

    value.onlyFields({"label", "value", "detail", "selected", "swatch"});
    const auto label = value.field("label");
    const auto chosen = value.field("value");
    const auto detail = value.field("detail");
    input.label = label.string();
    if (chosen.present()) {
      input.value = chosen.string();
    }

    if (detail.present()) {
      input.detail = detail.string();
    }

    input.selected = value.field("selected").boolean(false);
    input.swatch = swatch(value.field("swatch"));
    items.keep(input);
  }

  static std::optional<PickSwatch> swatch(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    PickSwatch result;
    if (value.arraySize() != result.size()) {
      value.fail("must contain three RGB colors");
    }

    constexpr int hexadecimal_base = 16;
    for (std::size_t index = 0; index < result.size(); ++index) {
      const auto color = value.element(static_cast<lua_Integer>(index) + 1);
      runtime::config::hexadecimalColor(color);
      const auto text = color.string();
      const auto parsed = std::from_chars(text.data() + 1, text.data() + text.size(), result[index], hexadecimal_base);
      if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
        color.fail("must be an RGB color");
      }
    }

    return result;
  }
};

}
