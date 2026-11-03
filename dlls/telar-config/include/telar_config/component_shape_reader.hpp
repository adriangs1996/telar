#pragma once

#include "telar_config/component_shape.hpp"
#include "telar_config/component_style_validator.hpp"
#include <limits>

namespace telar::runtime::config {

class ComponentShapeReader {
public:
  static ComponentShape read(const lua::Value &value, unsigned inherited_priority, LimitNotices &limits) {
    ComponentShape shape;
    shape.kind = kind(value.field("ui"));
    fields(value, shape.kind);
    shape.priority = static_cast<unsigned>(std::round(value.field("priority").boundedNumber(inherited_priority, 0, 100)));
    const auto tone = value.field("tone");
    optionalChoice(tone, {"neutral", "muted", "accent", "success", "warning", "danger"});
    if (tone.present()) {
      shape.tone_bonus = tone.string() == "danger" ? 40 : tone.string() == "warning" ? 20
                                                                                     : 0;
    }

    switch (shape.kind) {
    case ComponentKind::label:
      shape.text = text(value, "text");
      ComponentStyleValidator::validate(value);
      break;
    case ComponentKind::icon:
      optionalIcon(value.field("name"));
      shape.text = text(value, "glyph");
      if (shape.text.size() > maximum_glyph_bytes || (shape.text.empty() && !value.field("name").present())) {
        value.fail("requires an icon name or a glyph of at most 16 bytes");
      }
      break;
    case ComponentKind::mark:
      uiMark(value.field("name"));
      break;
    case ComponentKind::meter:
    case ComponentKind::meter_row:
      finiteNumber(value.field("value"));
      finiteNumber(value.field("marker"));
      shape.text = text(value, "label");
      shape.detail = text(value, shape.kind == ComponentKind::meter ? "text" : "detail");
      break;
    case ComponentKind::sparkline:
      shape.samples = samples(value, limits);
      break;
    case ComponentKind::badge:
    case ComponentKind::heading:
    case ComponentKind::text:
      shape.text = text(value, "text");
      break;
    case ComponentKind::clock:
      shape.text = text(value, "format", "%H:%M");
      if (shape.text.size() > maximum_clock_bytes) {
        value.fail("exceeds the clock format limit");
      }
      break;
    case ComponentKind::metric:
      value.field("name").string();
      optionalChoice(value.field("name"), {"cpu", "memory", "battery"});
      break;
    case ComponentKind::group:
      optionalIcon(value.field("icon"));
      if (const auto mark = value.field("mark"); mark.present()) {
        uiMark(mark);
      }
      shape.action_field = value.field("on_click").present() ? "on_click" : nullptr;
      shape.url = text(value, "url");
      break;
    case ComponentKind::key_value:
      shape.text = text(value, "key");
      shape.detail = text(value, "value");
      break;
    case ComponentKind::callout:
      optionalIcon(value.field("icon"));
      shape.text = text(value, "text");
      shape.detail = text(value, "detail");
      break;
    case ComponentKind::button:
      shape.text = text(value, "text");
      shape.action_field = value.field("action").present() ? "action" : nullptr;
      shape.url = text(value, "url");
      value.field("primary").boolean(false);
      if (shape.action_field == nullptr && shape.url.empty()) {
        value.fail("requires an action or URL");
      }
      break;
    case ComponentKind::machines:
    case ComponentKind::actions:
    case ComponentKind::divider:
      break;
    }
    return shape;
  }

  static ComponentShape segment(const lua::Value &value, unsigned priority) {
    value.onlyFields({"text", "icon", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
    ComponentShape shape;
    shape.text = text(value, "text");
    shape.kind = shape.text.empty() ? ComponentKind::icon : ComponentKind::label;
    shape.priority = priority;
    optionalIcon(value.field("icon"));
    ComponentStyleValidator::validate(value);
    return shape;
  }

private:
  static ComponentKind kind(const lua::Value &value) {
    constexpr std::string_view names[]{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
    const auto found = std::ranges::find(names, value.string());
    if (found == std::end(names)) {
      value.fail("names an unknown component");
    }
    return static_cast<ComponentKind>(found - std::begin(names));
  }

  static void fields(const lua::Value &value, ComponentKind kind) {
    switch (kind) {
    case ComponentKind::label:
      value.onlyFields({"ui", "text", "tone", "priority", "fg", "bg", "bold", "italic", "faint", "underline", "strikethrough"});
      break;
    case ComponentKind::icon:
      value.onlyFields({"ui", "name", "glyph", "tone", "priority"});
      break;
    case ComponentKind::mark:
    case ComponentKind::metric:
      value.onlyFields({"ui", "name", "priority"});
      break;
    case ComponentKind::meter:
      value.onlyFields({"ui", "value", "label", "text", "marker", "tone", "priority"});
      break;
    case ComponentKind::meter_row:
      value.onlyFields({"ui", "value", "label", "detail", "marker", "tone", "priority"});
      break;
    case ComponentKind::sparkline:
      value.onlyFields({"ui", "values", "max", "tone", "priority"});
      break;
    case ComponentKind::badge:
    case ComponentKind::heading:
    case ComponentKind::text:
      value.onlyFields({"ui", "text", "tone", "priority"});
      break;
    case ComponentKind::clock:
      value.onlyFields({"ui", "format", "tone", "priority"});
      break;
    case ComponentKind::machines:
    case ComponentKind::divider:
      value.onlyFields({"ui", "priority"});
      break;
    case ComponentKind::group:
      value.onlyFields({"ui", "mark", "icon", "tooltip", "on_click", "url", "priority", "tone"}, true);
      break;
    case ComponentKind::key_value:
      value.onlyFields({"ui", "key", "value", "tone", "priority"});
      break;
    case ComponentKind::callout:
      value.onlyFields({"ui", "icon", "text", "detail", "button", "tone", "priority"});
      break;
    case ComponentKind::button:
      value.onlyFields({"ui", "text", "action", "url", "primary", "tone", "priority"});
      break;
    case ComponentKind::actions:
      value.onlyFields({"ui", "priority"}, true);
      break;
    }
  }

  static std::string_view text(const lua::Value &value, const char *name, std::string_view fallback = {}) {
    const auto field = value.field(name);
    return field.present() ? field.string() : fallback;
  }

  static void optionalIcon(const lua::Value &value) {
    if (value.present()) {
      uiIcon(value);
    }
  }

  static void finiteNumber(const lua::Value &value) {
    value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
  }

  static std::size_t samples(const lua::Value &value, LimitNotices &limits) {
    finiteNumber(value.field("max"));
    const auto values = value.field("values");
    const auto total = values.listLength();
    const auto kept = std::min(total, maximum_samples);
    if (total > kept) {
      limits.add({"bars.max_node_samples", "sparkline values", maximum_samples, total, {}});
    }
    for (std::size_t index = total - kept + 1; index <= total; ++index) {
      const auto sample = values.element(index);
      if (!sample.present()) {
        sample.fail("must be a number");
      }
      sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
    }
    return kept;
  }

  static constexpr std::size_t maximum_glyph_bytes = 16;
  static constexpr std::size_t maximum_clock_bytes = 32;
  static constexpr std::size_t maximum_samples = 120;
};

}
