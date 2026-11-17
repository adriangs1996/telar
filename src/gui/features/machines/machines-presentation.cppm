// How the chrome shows the machines: each one's glyph, phase and CPU, and the geometry of the
// switcher, the segments and the list.
export module telar.gui.features.machines:presentation;

import std;

import :roster;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

// Interface: presentation/machine_facts.cppm
export {
  namespace telar::gui::features::machines {

    struct MachineFacts {
      static constexpr float machine_gap = 12;
      static constexpr float part_gap = 5;
      static constexpr std::size_t cpu_capacity = 8;
      using CpuText = BoundedText<cpu_capacity>;

      struct Widths {
        float glyph = 0;
        float label = 0;
        float cpu = 0;
      };

      struct Geometry {
        Rect bounds;
        Rect glyph;
        Rect label;
        Rect cpu;
      };

      [[nodiscard]] static std::string_view glyph(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static PaletteRole glyphInk(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static std::string_view phaseName(MachinePhase phase) noexcept;
      [[nodiscard]] static CpuText cpu(MachinePhase phase, std::optional<std::uint8_t> percent);
      [[nodiscard]] static float width(const ChromeMetrics& chrome, Widths parts) noexcept;
      [[nodiscard]] static Geometry geometry(Rect area, const ChromeMetrics& chrome, Widths parts) noexcept;
    };

  }
}

// Interface: presentation/machine_chrome_geometry.cppm
export {
  namespace telar::gui::features::machines {

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
