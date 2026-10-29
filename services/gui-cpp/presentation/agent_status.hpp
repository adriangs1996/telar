#pragma once

#include "core/theme_values.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

struct AgentStatusPresentation {
  static constexpr std::uint32_t seconds_per_minute = 60;
  static constexpr std::uint32_t seconds_per_hour = 60 * seconds_per_minute;
  static constexpr std::uint32_t seconds_per_day = 24 * seconds_per_hour;
  static constexpr std::uint32_t maximum_days = 9999;
  static constexpr std::size_t age_capacity = 8;
  static constexpr std::size_t text_capacity = 32;
  using Text = BoundedText<text_capacity>;
  using Age = BoundedText<age_capacity>;

  [[nodiscard]] static std::string_view word(AgentStatus status, AgentBlockedReason reason) noexcept {
    switch (status) {
    case AgentStatus::working:
      return "Working";
    case AgentStatus::blocked:
      switch (reason) {
      case AgentBlockedReason::permission:
        return "Approval";
      case AgentBlockedReason::question:
        return "Question";
      case AgentBlockedReason::plan:
        return "Review plan";
      default:
        return "Needs input";
      }
    case AgentStatus::done:
      return "Done";
    case AgentStatus::failed:
      return "Failed";
    case AgentStatus::ready:
      return {};
    case AgentStatus::unknown:
      return "Unknown";
    }

    return {};
  }

  [[nodiscard]] static std::string_view glyph(AgentStatus status, AgentBlockedReason reason) noexcept {
    switch (status) {
    case AgentStatus::blocked:
      switch (reason) {
      case AgentBlockedReason::permission:
        return "\u26a0";
      case AgentBlockedReason::question:
        return "?";
      case AgentBlockedReason::plan:
        return "\u2261";
      default:
        return "!";
      }
    case AgentStatus::working:
      return "\u25cc";
    case AgentStatus::done:
      return "\u2713";
    case AgentStatus::failed:
      return "\u2715";
    case AgentStatus::ready:
      return "\u00b7";
    case AgentStatus::unknown:
      return "?";
    }

    return {};
  }

  [[nodiscard]] static PaletteRole color(AgentStatus status) noexcept {
    switch (status) {
    case AgentStatus::working:
      return PaletteRole::teal;
    case AgentStatus::done:
      return PaletteRole::green;
    case AgentStatus::blocked:
      return PaletteRole::yellow;
    case AgentStatus::failed:
      return PaletteRole::red;
    default:
      return PaletteRole::overlay1;
    }
  }

  [[nodiscard]] static Age age(std::uint32_t seconds, bool duration = false) {
    Age result;
    if (seconds < seconds_per_minute) {
      if (duration) {
        result.appendDecimal(seconds);
        result.append("s");
      } else {
        result.append("now");
      }
    } else if (seconds < seconds_per_hour) {
      result.appendDecimal(seconds / seconds_per_minute);
      result.append("m");
    } else if (seconds < seconds_per_day) {
      result.appendDecimal(seconds / seconds_per_hour);
      result.append("h");
    } else {
      result.appendDecimal(std::min(seconds / seconds_per_day, maximum_days));
      result.append("d");
    }

    return result;
  }

  [[nodiscard]] static Text text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds, bool connected = true) {
    Text result;
    if (status == AgentStatus::ready && connected) {
      result.append(age(seconds).view());
    } else {
      result.append(connected ? word(status, reason) : "offline");
      if (status == AgentStatus::working && connected) {
        result.append(" ");
        result.append(age(seconds, true).view());
      }
    }

    return result;
  }

  [[nodiscard]] static float pulse(std::uint8_t frame) noexcept {
    constexpr unsigned frame_count = 17;
    constexpr unsigned step_count = 6;
    constexpr float middle_step = 3;
    constexpr float minimum_alpha = 0.65F;
    constexpr float alpha_range = 0.35F;
    const auto quantized_step = (static_cast<unsigned>(frame) % frame_count) * step_count / frame_count;
    const auto step = static_cast<float>(quantized_step);
    const auto scaled_alpha = alpha_range * std::abs(step - middle_step) / middle_step;

    return minimum_alpha + scaled_alpha;
  }
};

}
