export module telar.gui.foundation.agents:agent_status;

import std;

import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

// Interface: presentation/agent_status.cppm
export {
  namespace telar::gui::inline foundation::inline agents {

    struct AgentStatusPresentation {
      static constexpr std::uint32_t seconds_per_minute = 60;
      static constexpr std::uint32_t seconds_per_hour = 60 * seconds_per_minute;
      static constexpr std::uint32_t seconds_per_day = 24 * seconds_per_hour;
      static constexpr std::uint32_t maximum_days = 9999;
      static constexpr std::size_t age_capacity = 8;
      static constexpr std::size_t text_capacity = 32;
      using Text = BoundedText<text_capacity>;
      using Age = BoundedText<age_capacity>;

      [[nodiscard]] static std::string_view word(AgentStatus status, AgentBlockedReason reason) noexcept;

      [[nodiscard]] static std::string_view glyph(AgentStatus status, AgentBlockedReason reason) noexcept;

      [[nodiscard]] static PaletteRole color(AgentStatus status) noexcept;

      [[nodiscard]] static Age age(std::uint32_t seconds, bool duration = false);

      [[nodiscard]] static Text text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds, bool connected = true);

      [[nodiscard]] static float pulse(std::uint8_t frame) noexcept;
    };

  }
}
