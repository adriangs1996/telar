export module telar.gui.foundation.core:view_version;

import std;

// Interface: core/view_version.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    struct ViewVersion {
      std::uint64_t workspace = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t tabs = 0;
      std::uint64_t panes = 0;
      std::uint64_t host = 0;
      std::uint64_t configuration = 0;
      std::uint64_t viewport = 0;
      std::uint64_t machine = 0;

      bool operator==(const ViewVersion&) const = default;
    };

  }
}
