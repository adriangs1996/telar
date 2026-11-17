export module telar.gui.presentation.application_mark;

import std;

import telar.wire.vocabulary;

// Interface: presentation/activity_card.cppm
export {
  namespace telar::gui {

    enum class ActivityCard : std::uint8_t {
      agent,
      task,
    };

  }
}

// Interface: presentation/application_mark.cppm
export {
  namespace telar::gui {

    struct ApplicationMark {
      static constexpr float dimmed_alpha = 0.6F;
      static constexpr float atlas_cell_side = 20;
      static constexpr int minimum_cell = 8;
      static constexpr int maximum_cell = 96;

      AgentProvider provider = AgentProvider::unknown;
      std::string_view glyph = "\uea85";
      std::string_view tile = "#2b2a3a";
      std::string_view ink = "#5fb095";

      [[nodiscard]] bool followsTheme() const noexcept;
      [[nodiscard]] static ApplicationMark forApplication(std::string_view name) noexcept;
    };

  }
}
