#pragma once

#include "component_validator.hpp"
#include "dynamic_source_validator.hpp"

namespace telar::runtime::config {

class BarsValidator {
public:
  explicit BarsValidator(const ActionValidator &actions, LimitNotices &limits)
      : actions_(actions),
        limits_(limits) {}

  void validate(const lua::Value &bars) const {
    if (!bars.present()) {
      return;
    }
    bars.onlyFields({"bottom", "top", "sidebar_footer"});
    bottom(bars.field("bottom"));
    const auto top = bars.field("top");
    if (top.present()) {
      top.onlyFields({"right"});
      const auto right = top.field("right");
      if (right.present() && source(right) == Source::tabs) {
        right.fail("cannot contain tabs");
      }
    }

    const auto footer = bars.field("sidebar_footer");
    if (footer.present()) {
      const auto count = footer.arraySize();
      if (count > maximum_footer_slots) {
        footer.fail("accepts at most three slots");
      }
      for (std::size_t index = 1; index <= count; ++index) {
        if (source(footer.element(index)) == Source::tabs) {
          footer.fail("cannot contain tabs");
        }
      }
    }
  }

private:
  enum class Source {
    content,
    tabs
  };

  void bottom(const lua::Value &bar) const {
    if (!bar.present()) {
      return;
    }
    bar.onlyFields({"left", "center", "right"});
    unsigned tabs = 0;
    for (const auto *name : {"left", "center", "right"}) {
      const auto value = bar.field(name);
      if (value.present() && source(value) == Source::tabs) {
        ++tabs;
      }
    }
    if (tabs != 1) {
      bar.fail("must contain exactly one tabs source");
    }
  }

  Source source(const lua::Value &value) const {
    const auto kind_value = value.field("bar_kind");
    const auto kind = kind_value.string();
    if (kind == "tabs" || kind == "metrics" || kind == "machines") {
      value.onlyFields({"bar_kind"});
      return kind == "tabs" ? Source::tabs : Source::content;
    }
    if (kind == "static") {
      value.onlyFields({"bar_kind", "value"});
      ComponentValidator{actions_, limits_}.validate(value.field("value"));
    } else {
      DynamicSourceValidator::validate(value);
    }
    return Source::content;
  }

  static constexpr std::size_t maximum_footer_slots = 3;
  const ActionValidator &actions_;
  LimitNotices &limits_;
};

}
