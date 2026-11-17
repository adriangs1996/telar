module telar.gui.foundation.agents;

import std;

import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline agents {

  std::string_view AgentStatusPresentation::word(AgentStatus status, AgentBlockedReason reason) noexcept {
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

  std::string_view AgentStatusPresentation::glyph(AgentStatus status, AgentBlockedReason reason) noexcept {
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

  PaletteRole AgentStatusPresentation::color(AgentStatus status) noexcept {
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

  auto AgentStatusPresentation::age(std::uint32_t seconds, bool duration) -> Age {
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

  auto AgentStatusPresentation::text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds, bool connected) -> Text {
    Text result;

    if (status == AgentStatus::ready && connected) {
      result.append(age(seconds).view());
    } else {
      result.append(connected ? word(status, reason) : "offline");
      // How long an agent has worked or waited is what decides which one to visit first.
      if (connected && status != AgentStatus::unknown) {
        result.append(" ");
        result.append(age(seconds, true).view());
      }
    }

    return result;
  }

  float AgentStatusPresentation::pulse(std::uint8_t frame) noexcept {
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

}
