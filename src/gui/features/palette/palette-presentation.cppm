// Where the palette, its rows and its suggestion pane sit, and what the suggestion pane says.
export module telar.gui.features.palette:presentation;

import std;

import :suggestion;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: presentation/palette_geometry.cppm
export {
  namespace telar::gui::features::palette {

    struct PaletteGeometry {
      struct Options {
        ds::Option<std::uint16_t> pick_rows;
        bool suggest = false;
      };

      static constexpr float maximum_width = 640;
      static constexpr float margin = 24;
      static constexpr float margin_divisor = 12;
      static constexpr float top_share = 0.11F;
      static constexpr float row_minimum = 38;
      static constexpr float row_padding = 16;
      static constexpr float agent_minimum = 52;
      static constexpr float agent_padding = 12;
      static constexpr float group_minimum = 28;
      static constexpr float group_padding = 10;
      static constexpr float heading_minimum = 32;
      static constexpr float heading_padding = 12;
      static constexpr float search_minimum = 60;
      static constexpr float search_padding = 24;
      static constexpr float tabs_minimum = 38;
      static constexpr float tabs_padding = 16;
      static constexpr float footer_minimum = 40;
      static constexpr float footer_padding = 16;
      static constexpr float list_padding = 22;
      static constexpr float pick_padding = 16;
      static constexpr float suggestion_height = 180;
      static constexpr std::uint16_t minimum_pick_rows = 3;
      static constexpr std::uint16_t maximum_pick_rows = 8;
      static constexpr float heading_divisor = 6;
      static constexpr float search_divisor = 2;
      static constexpr float tabs_divisor = 4;
      static constexpr float footer_divisor = 3;

      Rect viewport;
      Rect bounds;
      Rect heading;
      Rect search;
      Rect tabs;
      Rect results;
      Rect footer;
      float row_height = 0;
      float agent_height = 0;
      float group_height = 0;

      [[nodiscard]] static PaletteGeometry measure(Rect viewport, const ChromeMetrics& chrome, Options options) noexcept;
      [[nodiscard]] static Rect inset(Rect bounds, float amount) noexcept;

    private:
      static Rect takeTop(Rect& remaining, float height) noexcept;
    };

  }
}

// Interface: presentation/palette_row_window.cppm
export {
  namespace telar::gui::features::palette {

    enum class PaletteRowKind : std::uint8_t {
      context,
      tab,
      agent,
      action,
      machine,
      pick,
    };

    struct PaletteRowWindow {
      static constexpr std::size_t capacity = 16;
      static constexpr float content_inset = 8;

      struct Row {
        std::size_t index = 0;
        Rect group;
        Rect bounds;
      };

      ds::Array<Row, capacity> rows{};
      std::size_t count = 0;
      std::size_t first = 0;

      [[nodiscard]] static PaletteRowWindow measure(std::span<const PaletteRowKind> kinds, std::size_t selection, const PaletteGeometry& geometry, const ChromeMetrics& chrome, bool grouped) noexcept;

    private:
      [[nodiscard]] static float rowHeight(PaletteRowKind kind, const PaletteGeometry& geometry) noexcept;
    };

  }
}

// Interface: presentation/suggestion_geometry.cppm
export {
  namespace telar::gui::features::palette {

    struct SuggestionGeometry {
      static constexpr float content_inset = 18;
      static constexpr float heading_padding = 8;
      static constexpr float body_gap = 8;
      static constexpr float preview_inset = 12;
      static constexpr float preview_radius = 6;
      static constexpr float button_width = 170;
      static constexpr float footer_inset = 14;
      static constexpr float button_vertical_inset = 4;
      static constexpr float footer_gap_count = 3;
      static constexpr float footer_separator_height = 1;
      static constexpr float message_alpha = 0.65F;
      static constexpr float title_alpha = 0.75F;
      static constexpr float title_inset = 8;
      static constexpr float back_width = 26;

      Rect title;
      Rect back;
      Rect heading;
      Rect body;
      Rect message;
      Rect preview;
      Rect footer_caption;
      Rect button;
      Rect separator;

      [[nodiscard]] static SuggestionGeometry measure(const PaletteGeometry& palette, const ChromeMetrics& chrome, bool has_parent) noexcept;
    };

  }
}

// Interface: presentation/suggestion_labels.cppm
export {
  namespace telar::gui::features::palette {

    struct SuggestionLabels {
      [[nodiscard]] static std::string_view heading(SuggestionPhase phase) noexcept;
      [[nodiscard]] static std::string_view message(SuggestionPhase phase, SuggestionStatus status) noexcept;
      [[nodiscard]] static std::string_view button(SuggestionPhase phase) noexcept;
      [[nodiscard]] static std::string_view footer(SuggestionPhase phase) noexcept;
      [[nodiscard]] static bool canSubmit(SuggestionPhase phase, std::string_view query) noexcept;
    };

  }
}
