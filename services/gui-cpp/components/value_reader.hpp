#pragma once

#include "config/limit_notices.hpp"
#include "config/ui_value_constraints.hpp"
#include "core/color_name.hpp"
#include "lua/value.hpp"
#include "memory/fixed_text.hpp"
#include "node.hpp"
#include "presentation/bar_metrics.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "text/ascii.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <lua.h>
#include <optional>
#include <string_view>
#include <utility>

namespace telar::gui::components {

struct SampleValues {
  std::array<std::uint8_t, Node::maximum_samples> values{};
  std::size_t length = 0;
};

class ValueReader {
public:
  static Style style(const runtime::lua::Value &value) {
    Style result;
    result.foreground = color(value.field("fg"));
    result.background = color(value.field("bg"));
    constexpr auto fields = std::to_array<std::pair<const char *, bool Style::*>>({
        {"bold", &Style::bold},
        {"italic", &Style::italic},
        {"faint", &Style::faint},
        {"underline", &Style::underline},
        {"strikethrough", &Style::strikethrough},
    });
    for (const auto &[name, member] : fields) {
      result.*member = value.field(name).boolean(false);
    }

    return result;
  }

  static Tone tone(const runtime::lua::Value &value) {
    if (!value.present()) {
      return Tone::neutral;
    }

    constexpr std::array names{"neutral", "muted", "accent", "success", "warning", "danger"};
    const auto name = value.string();
    for (std::size_t index = 0; index < names.size(); ++index) {
      if (name == names[index]) {
        return static_cast<Tone>(index);
      }
    }

    value.fail("names an unknown component tone");
  }

  static std::optional<Mark> mark(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    runtime::config::uiMark(value);
    constexpr std::array names{"claude", "codex", "pi", "telar"};
    const auto name = value.string();

    return static_cast<Mark>(std::ranges::find(names, name) - names.begin());
  }

  static BarMetric metric(const runtime::lua::Value &value) {
    constexpr std::array names{"cpu", "memory", "battery"};
    const auto name = value.string();
    const auto *const found = std::ranges::find(names, name);
    if (found == names.end()) {
      value.fail("names an unknown component metric");
    }

    return static_cast<BarMetric>(found - names.begin());
  }

  static std::optional<runtime::FixedText<Node::maximum_icon_bytes>> icon(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    runtime::config::uiIcon(value);
    runtime::FixedText<Node::maximum_icon_bytes> result;
    std::array<char, Node::maximum_icon_bytes> normalized{};
    const auto name = value.string();
    if (name.size() > normalized.size()) {
      value.fail("exceeds the component icon name limit");
    }

    std::ranges::transform(name, normalized.begin(), [](char byte) {
      return byte == '-' ? '_' : runtime::asciiLower(byte);
    });
    result.assign({normalized.data(), name.size()});

    return result;
  }

  static std::optional<std::uint16_t> fraction(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    const auto number = value.boundedNumber(0, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());

    return static_cast<std::uint16_t>(std::round(std::clamp(number, 0.0, 1.0) * Node::full_scale));
  }

  static SampleValues samples(const runtime::lua::Value &value, runtime::config::LimitNotices &limits) {
    const auto maximum = value.field("max");
    const auto values = value.field("values");
    const auto total = values.listLength();
    SampleValues result;
    result.length = std::min(total, result.values.size());
    if (total > result.length) {
      limits.add({.name = "bars.max_node_samples", .noun = "sparkline values", .value = Node::maximum_samples, .requested = total, .route = {}});
    }

    std::array<double, Node::maximum_samples> kept{};
    double largest = 0;
    for (std::size_t index = 0; index < result.length; ++index) {
      const auto sample = values.element(static_cast<lua_Integer>(total - result.length) + static_cast<lua_Integer>(index) + 1);
      if (!sample.present()) {
        sample.fail("must be a number");
      }

      const auto number = sample.boundedNumber(0, 0, std::numeric_limits<double>::max());
      kept[index] = number;
      largest = std::max(largest, number);
    }

    const auto scale = maximum.boundedNumber(largest, std::numeric_limits<double>::lowest(), std::numeric_limits<double>::max());
    constexpr double percent_scale = 100;
    for (std::size_t index = 0; index < result.length; ++index) {
      const auto fraction = scale > 0 ? std::clamp(kept[index] / scale, 0.0, 1.0) : 0;
      result.values[index] = static_cast<std::uint8_t>(std::round(fraction * percent_scale));
    }

    return result;
  }

private:
  static std::optional<ColorName::Value> color(const runtime::lua::Value &value) {
    if (!value.present()) {
      return std::nullopt;
    }

    constexpr auto maximum_index = std::numeric_limits<std::uint8_t>::max();
    if (const auto index = value.asInteger()) {
      if (*index < 0 || std::cmp_greater(*index, maximum_index)) {
        value.fail("is outside the component color index range");
      }

      return CellColor{.kind = CellColor::Kind::indexed, .channels = {static_cast<std::uint8_t>(*index), 0, 0}};
    }

    const auto parsed = ColorName::parse(value.string());
    if (!parsed) {
      value.fail("is not a supported component color");
    }

    return parsed;
  }
};

}
