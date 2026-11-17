export module telar.gui.presentation.suggestion_geometry;

import std;

import telar.gui.foundation.core;

// Interface: presentation/link_status_geometry.cppm
export {
  namespace telar::gui {

    struct LinkStatusGeometry {
      static constexpr float dim_alpha = 0.6F;
      static constexpr float line_height_factor = 1.5F;
      static constexpr float line_gap = 6;
      static constexpr float inset = 24;

      Rect bounds;
      Rect headline;
      Rect detail;

      [[nodiscard]] static LinkStatusGeometry measure(Rect area, const ChromeMetrics& chrome, bool has_detail) noexcept;
    };

  }
}

// Interface: presentation/machine_chrome_geometry.cppm
export {
  namespace telar::gui {

    struct MachineChromeGeometry {
      static constexpr float switcher_disc = 7;
      static constexpr float switcher_padding = 8;
      static constexpr float switcher_gap = 4;
      static constexpr float maximum_control = 120;
      static constexpr float segment_disc = 8;
      static constexpr float segment_padding = 10;
      static constexpr float segment_gap = 6;
      static constexpr float maximum_segment = 200;
      static constexpr float attention_diameter = 6;
      static constexpr float attention_gap = 6;

      enum class Kind : std::uint8_t {
        switcher,
        segment,
        fold,
      };

      static constexpr float list_vertical_padding = 5;
      static constexpr float list_padding = 8;
      // As wide as an agent card's mark column, so labels share the cards' text column.
      static constexpr float list_avatar = 24;
      static constexpr float list_gap = 6;
      static constexpr float list_dot = 7;
      static constexpr float list_dot_overhang = 2;
      // The tab strip's front card and the two slivers behind it, with room for their tilt.
      static constexpr float stack_width = 42;

      struct ListRow {
        Rect bounds;
        Rect avatar;
        Rect dot;
        Rect label;
        Rect status;
        Rect stack;
      };

      struct Control {
        Rect bounds;
        Rect label;
        Rect disc;
        Rect attention;
        float radius = 0;
      };

      static constexpr std::size_t list_status_capacity = 32;

      // What a machine row reads under its label: that its link is down, or how many of its
      // agents work or wait.
      [[nodiscard]] static std::string_view listStatus(bool live, std::size_t agents, std::span<char, list_status_capacity> storage) noexcept;

      // The sidebar lists the machines other than the active one, one row each: the machine's
      // avatar with its connection dot, its label over its status line and, on the right, the
      // stack of its agents that work or wait.
      [[nodiscard]] static float listRowHeight(const ChromeMetrics& chrome) noexcept;
      [[nodiscard]] static float listHeight(const ChromeMetrics& chrome, std::size_t rows) noexcept;

      // The width that shows a row's whole label and status line, whichever advances further.
      [[nodiscard]] static float listNaturalWidth(const ChromeMetrics& chrome, float text_advance, bool stacked) noexcept;
      [[nodiscard]] static ListRow listRow(Rect area, const ChromeMetrics& chrome, std::size_t index, bool stacked) noexcept;
      [[nodiscard]] static float preferredSegment(const ChromeMetrics& chrome, float advance) noexcept;
      [[nodiscard]] static Control control(Rect area, const ChromeMetrics& chrome, Kind kind, float advance, bool attention) noexcept;
    };

  }
}

// Interface: presentation/palette_geometry.cppm
export {
  namespace telar::gui {

    struct PaletteGeometry {
      struct Options {
        std::optional<std::uint16_t> pick_rows;
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
  namespace telar::gui {

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

      std::array<Row, capacity> rows{};
      std::size_t count = 0;
      std::size_t first = 0;

      [[nodiscard]] static PaletteRowWindow measure(std::span<const PaletteRowKind> kinds, std::size_t selection, const PaletteGeometry& geometry, const ChromeMetrics& chrome, bool grouped) noexcept;

    private:
      [[nodiscard]] static float rowHeight(PaletteRowKind kind, const PaletteGeometry& geometry) noexcept;
    };

  }
}

// Interface: presentation/sidebar_geometry.cppm
export {
  namespace telar::gui {

    // Whether the sidebar shows its machine section, and how many machine rows it lists.
    struct SidebarMachines {
      bool shown = false;
      std::size_t rows = 0;

      bool operator==(const SidebarMachines&) const = default;
    };

    struct SidebarGeometry {
      static constexpr float margin = 8;
      static constexpr float workspace_vertical_padding = 20;
      // The room between two sections, which their separator halves.
      static constexpr float section_gap = 16;

      [[nodiscard]] static float sectionGap(const ChromeMetrics& chrome) noexcept;

      Rect machines_header;
      Rect machines;
      Rect projects_header;
      Rect projects;
      Rect activity_header;
      Rect activity;

      [[nodiscard]] static float workspaceHeight(const ChromeMetrics& chrome) noexcept;
      [[nodiscard]] static SidebarGeometry measure(Rect area, const ChromeMetrics& chrome, std::size_t, SidebarMachines machines = {}) noexcept;
    };

  }
}

// Interface: presentation/suggestion_geometry.cppm
export {
  namespace telar::gui {

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
