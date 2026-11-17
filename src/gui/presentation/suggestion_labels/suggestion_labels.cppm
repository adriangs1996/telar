export module telar.gui.presentation.suggestion_labels;

import std;

import telar.gui.foundation.core;

import telar.gui.suggestions.state;
import telar.wire.vocabulary;

// Interface: presentation/agent_animation.cppm
export {
  namespace telar::gui {

    struct AgentAnimation {
      static constexpr std::uint64_t pulse_interval_ns = 120'000'000;

      [[nodiscard]] static float alpha(std::uint64_t now_ns) noexcept;
      [[nodiscard]] static std::optional<std::uint64_t> deadline(AgentStatus status, bool connected, std::uint64_t now_ns) noexcept;
    };

  }
}

// Interface: presentation/attachment_modal_geometry.cppm
export {
  namespace telar::gui {

    struct AttachmentModalGeometry {
      static constexpr std::uint16_t margin_columns = 8;
      static constexpr std::uint16_t margin_rows = 4;
      static constexpr std::uint16_t minimum_content_rows = 3;

      CellRectangle bounds{};
      CellRectangle title{};
      CellRectangle close{};
      CellRectangle image{};
      CellRectangle footer{};

      [[nodiscard]] static AttachmentModalGeometry measure(CellRectangle host) noexcept;
    };

  }
}

// Interface: presentation/suggestion_labels.cppm
export {
  namespace telar::gui {

    struct SuggestionLabels {
      [[nodiscard]] static std::string_view heading(SuggestionPhase phase) noexcept;
      [[nodiscard]] static std::string_view message(SuggestionPhase phase, SuggestionStatus status) noexcept;
      [[nodiscard]] static std::string_view button(SuggestionPhase phase) noexcept;
      [[nodiscard]] static std::string_view footer(SuggestionPhase phase) noexcept;
      [[nodiscard]] static bool canSubmit(SuggestionPhase phase, std::string_view query) noexcept;
    };

  }
}
