export module telar.gui.foundation.agents:agent_card_labels;

import std;

import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.text;

// Interface: presentation/agent_card_labels.cppm
export {
  namespace telar::gui::inline foundation::inline agents {

    struct AgentCardLabels {
      static constexpr std::string_view generic_name = "Agent";
      static constexpr std::string_view separator = " · ";
      static constexpr std::string_view coordinator_suffix = " · coordinator";
      static constexpr std::size_t workspace_capacity = 48;
      static constexpr std::size_t machine_capacity = 32;
      static constexpr std::size_t suffix_capacity = 32;
      using Project = BoundedText<workspace_capacity + machine_capacity + suffix_capacity>;

      [[nodiscard]] static tbc::val_a<std::string_view> title(tbc::val_a<std::string_view> session, tbc::val_a<std::string_view> display_name) noexcept;
      [[nodiscard]] static std::string_view providerGlyph(AgentProvider provider, std::string_view custom) noexcept;
      // The label is written into the storage, or is one of the names when it does not fit: region `a`.
      [[nodiscard]] static tbc::val_a<std::string_view> project(tbc::val_a<std::string_view> workspace, tbc::val_a<std::string_view> machine, bool coordinator, tbc::mut_a<Project> storage);
    };

  }
}
