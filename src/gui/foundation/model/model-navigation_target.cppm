export module telar.gui.foundation.model:navigation_target;

import std;

import telar.wire.vocabulary;

// Interface: palette/navigation_target.cppm
export {
  namespace telar::gui::inline foundation::inline model {

    struct AgentNavigationTarget {
      std::uint64_t pane_id = 0;
      std::uint64_t pane_generation = 0;

      bool operator==(const AgentNavigationTarget&) const = default;
    };

    using NavigationTarget = std::variant<WorkspaceLocation, TabLocation, AgentNavigationTarget>;

  }
}
