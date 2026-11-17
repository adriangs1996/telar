export module telar.gui.presentation.history_filter_geometry;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.text;

import telar.gui.machines.picker;

// Interface: presentation/machine_facts.cppm
export {
  namespace telar::gui {

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
