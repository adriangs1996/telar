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

// Interface: presentation/name_prompt_geometry.cppm
export {
  namespace telar::gui {

    struct NamePromptGeometry {
      static constexpr std::uint16_t requested_width = 64;
      static constexpr std::uint16_t requested_height = 7;
      static constexpr std::uint16_t horizontal_threshold = 12;
      static constexpr std::uint16_t vertical_threshold = 6;
      static constexpr std::uint16_t horizontal_margin = 2;
      static constexpr std::uint16_t vertical_margin = 1;

      CellRectangle bounds;
      CellRectangle title;
      CellRectangle field;
      CellRectangle footer;

      [[nodiscard]] static NamePromptGeometry measure(CellRectangle host, CellRectangle wanted = {.width = requested_width, .height = requested_height}) noexcept;

    private:
      [[nodiscard]] static std::uint16_t coordinate(std::uint32_t value) noexcept;
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

// Interface: presentation/modal_motion.cppm
export {
  namespace telar::gui {

    class ModalMotion {
    public:
      static constexpr std::uint64_t duration_ns = 220'000'000;

      [[nodiscard]] float sample(std::optional<std::uint64_t> generation, std::optional<std::uint64_t> timestamp) noexcept;
      [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept;

    private:
      [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept;

      std::optional<std::uint64_t> generation_;
      std::optional<std::uint64_t> started_ns_;
    };

  }
}

// Interface: presentation/peek_geometry.cppm
export {
  namespace telar::gui {

    struct PeekGeometry {
      static constexpr CellRectangle requested_size{.width = 96, .height = 24};
      static constexpr std::uint16_t chrome_rows = 4;
      static constexpr std::uint16_t field_rows_from_end = 2;

      CellRectangle bounds;
      CellRectangle title;
      CellRectangle facts;
      CellRectangle screen;
      CellRectangle field;
      CellRectangle footer;

      [[nodiscard]] static PeekGeometry measure(CellRectangle host) noexcept;
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
