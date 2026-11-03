#pragma once

#include "telar_config/ui_value_constraints.hpp"

namespace telar::runtime::config {

class PickItemsValidator {
public:
  explicit PickItemsValidator(LimitNotices &limits)
      : limits_(limits) {}

  void validate(const lua::Value &items) {
    const auto count = items.arraySize();
    for (std::size_t index = 1; index <= count; ++index) {
      const auto item = items.element(index);
      if (item.is(LUA_TSTRING)) {
        const auto label = item.string();
        keep(item, label, label, {});
        continue;
      }

      item.onlyFields({"label", "value", "detail", "selected", "swatch"});
      const auto label = item.field("label");
      const auto value = item.field("value");
      const auto detail = item.field("detail");
      item.field("selected").boolean(false);
      swatch(item.field("swatch"));
      keep(item, label.string(), value.present() ? value.string() : label.string(), detail.present() ? detail.string() : std::string_view{});
    }

    if (count > maximum_items) {
      limits_.add({"picks.max_items", "options", maximum_items, count, {}});
    }
    if (text_full_) {
      limits_.add({"picks.max_text_bytes", "option text bytes", maximum_text_bytes, offered_text_bytes_, {}});
    }
    const std::array<LimitReach, 3> text_limits{{
        {"picks.max_label_bytes", "label bytes", maximum_label_bytes, longest_label_, {}},
        {"picks.max_value_bytes", "value bytes", maximum_value_bytes, longest_value_, {}},
        {"picks.max_detail_bytes", "detail bytes", maximum_detail_bytes, longest_detail_, {}},
    }};
    for (const auto &reach : text_limits) {
      if (reach.requested > reach.value) {
        limits_.add(reach);
      }
    }
  }

private:
  void keep(const lua::Value &item, std::string_view label, std::string_view value, std::string_view detail) {
    offered_text_bytes_ += label.size() + value.size() + detail.size();
    longest_label_ = std::max(longest_label_, label.size());
    longest_detail_ = std::max(longest_detail_, detail.size());
    longest_value_ = std::max(longest_value_, value.size());
    label = utf8Prefix(label, maximum_label_bytes);
    detail = utf8Prefix(detail, maximum_detail_bytes);
    if (value.size() > maximum_value_bytes) {
      return;
    }
    if (kept_items_ == maximum_items || text_full_) {
      return;
    }

    if (label.empty() || value.empty()) {
      item.fail("needs a nonempty label and value");
    }
    printableUiText(item, label);
    printableUiText(item, detail);
    printableUiText(item, value, true);

    const auto needed = label.size() + detail.size() + (label == value ? 0 : value.size());
    if (text_bytes_ + needed > maximum_text_bytes) {
      text_full_ = true;
      return;
    }
    text_bytes_ += needed;
    ++kept_items_;
  }

  static void swatch(const lua::Value &value) {
    if (!value.present()) {
      return;
    }
    if (value.arraySize() != 3) {
      value.fail("must contain three RGB colors");
    }
    for (lua_Integer index = 1; index <= 3; ++index) {
      hexadecimalColor(value.element(index));
    }
  }

  static constexpr std::size_t maximum_items = 4096;
  static constexpr std::size_t maximum_text_bytes = 256 * 1024;
  static constexpr std::size_t maximum_label_bytes = 128;
  static constexpr std::size_t maximum_value_bytes = 512;
  static constexpr std::size_t maximum_detail_bytes = 128;

  LimitNotices &limits_;
  std::size_t kept_items_ = 0;
  std::size_t text_bytes_ = 0;
  std::size_t offered_text_bytes_ = 0;
  std::size_t longest_label_ = 0;
  std::size_t longest_value_ = 0;
  std::size_t longest_detail_ = 0;
  bool text_full_ = false;
};

}
