#pragma once

#include "telar_config/action_validator.hpp"
#include "telar_config/component_budget.hpp"
#include "telar_config/component_shape_reader.hpp"

namespace telar::runtime::config {

template <CommandTabStore Commands>
class ComponentValidator {
public:
  explicit ComponentValidator(const BasicActionValidator<Commands> &actions, LimitNotices &limits)
      : actions_(actions),
        limits_(limits) {}

  void validate(const lua::Value &value) {
    // Rank the whole result before validating actions: components excluded
    // from staging must not retain commands or reject the configuration.
    walk(value, {});
    budget_.prepare();
    counting_ = false;
    walk(value, {});
    budget_.report(limits_);
  }

private:
  enum class Place {
    bar,
    group,
    tooltip,
    buttons
  };

  struct Position {
    Place place = Place::bar;
    unsigned priority = 50;
    unsigned rank = UINT8_MAX;
    unsigned depth = 0;
  };

  void walk(const lua::Value &value, Position position) {
    if (!value.present()) {
      return;
    }
    if (value.is(LUA_TSTRING)) {
      append(value, {.text = value.string(), .priority = position.priority}, position);
      return;
    }
    if (value.field("ui").present()) {
      component(value, position);
      return;
    }
    if (value.field("text").present() || value.field("icon").present()) {
      append(value, ComponentShapeReader::segment(value, position.priority), position);
      return;
    }
    if (position.depth == maximum_list_depth) {
      value.fail("exceeds the component nesting limit");
    }

    ++position.depth;
    const auto count = value.arraySize();
    for (std::size_t index = 1; index <= count; ++index) {
      walk(value.element(index), position);
    }
  }

  void component(const lua::Value &value, Position position) {
    const auto shape = ComponentShapeReader::read(value, position.priority, limits_);
    if (!append(value, shape, position)) {
      return;
    }

    const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);
    if (shape.kind == ComponentKind::group) {
      children(value, {Place::group, shape.priority, rank});
      walk(value.field("tooltip"), {Place::tooltip, default_priority, rank});
    } else if (shape.kind == ComponentKind::callout) {
      walk(value.field("button"), {Place::buttons, default_priority, rank});
    } else if (shape.kind == ComponentKind::actions) {
      children(value, {Place::buttons, default_priority, rank});
    }
  }

  void children(const lua::Value &value, Position position) {
    const auto count = value.listLength();
    for (std::size_t index = 1; index <= count; ++index) {
      walk(value.element(index), position);
    }
  }

  bool append(const lua::Value &value, const ComponentShape &shape, Position position) {
    if (!allowed(shape.kind, position.place)) {
      value.fail("contains a component unsupported in this position");
    }

    const auto rank = std::min(shape.priority + shape.tone_bonus, position.rank);
    if (counting_) {
      budget_.count(shape, rank);
      return true;
    }
    if (!budget_.admit(shape, rank)) {
      return false;
    }
    if (shape.action_field != nullptr && !actions_.component(value.field(shape.action_field))) {
      budget_.release(shape, rank);
      return false;
    }
    if (budget_.nodesFull()) {
      return false;
    }

    validateUrl(value, shape.url);
    if (!budget_.stage(shape)) {
      return false;
    }
    printableUiText(value, shape.text);
    printableUiText(value, shape.detail);
    return true;
  }

  static bool allowed(ComponentKind kind, Place place) noexcept {
    switch (place) {
    case Place::bar:
      return kind <= ComponentKind::group;
    case Place::group:
      return kind < ComponentKind::group;
    case Place::tooltip:
      return kind != ComponentKind::group && kind != ComponentKind::callout && kind != ComponentKind::actions && kind != ComponentKind::button;
    case Place::buttons:
      return kind == ComponentKind::button;
    }
    return false;
  }

  static void validateUrl(const lua::Value &value, std::string_view url) {
    if (url.empty()) {
      return;
    }
    if (url.size() > maximum_url_bytes || url.contains(' ') || (!url.starts_with("https://") && !url.starts_with("http://"))) {
      value.fail("requires an HTTP or HTTPS URL without spaces");
    }
    printableUiText(value, url);
  }

  static constexpr unsigned maximum_list_depth = 4;
  static constexpr unsigned default_priority = 50;
  static constexpr std::size_t maximum_url_bytes = 1024;
  const BasicActionValidator<Commands> &actions_;
  LimitNotices &limits_;
  ComponentBudget budget_;
  bool counting_ = true;
};

}
