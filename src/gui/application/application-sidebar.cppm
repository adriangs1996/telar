export module telar.gui.application:sidebar;

import std;
import telar.gui.foundation.core;

// Interface: presentation/sidebar_columns.cppm
export {
  namespace telar::gui::application {

    struct SidebarColumns {
      static constexpr std::uint16_t minimum_width = 42;
      static constexpr std::uint16_t minimum_workbench = 20;

      [[nodiscard]] static std::uint16_t clamp(std::uint16_t host_width, std::int64_t requested_width);
    };

  }
}

// Interface: presentation/sidebar_geometry.cppm
export {
  namespace telar::gui::application {

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
