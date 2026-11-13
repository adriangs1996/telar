module;
#include <cstdint>

export module telar.gui.tests.agent_fixture;

import std;
export import telar.client.protocol;

export {
namespace telar::gui::test {

inline AgentSnapshotEntry agentSnapshotEntry(std::uint32_t age_seconds = 0) {
  return {
      .pane_id = 1,
      .pane_generation = 1,
      .location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1},
      .pane_index = 1,
      .session_title = "Initial",
      .provider = AgentProvider::codex,
      .status = AgentStatus::working,
      .status_age_s = age_seconds,
      .sequence = 1,
  };
}

}
}
