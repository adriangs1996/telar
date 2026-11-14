module telar.wire.layout;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void UpdateClientLayout::validate() const {
    if (sidebar_width == 0) {
      throw EncodingError{"Invalid sidebar width"};
    }

    validateLayoutCollection(active_tab, tabs);
  }

  void RequestPaneFocus::validate() const {
    if (pane_generation == 0) {
      throw EncodingError{"Invalid pane generation"};
    }
  }

  void CompletePaneFocus::validate() const {
    if (pane_generation == 0 || (outcome == PaneFocusOutcome::focused && focused_pane_id == 0)) {
      throw EncodingError{"Invalid focus completion"};
    }
  }

  void TabSnapshot::validate() const {
    for (std::size_t i = 0; i < panes.size(); ++i) {
      for (std::size_t j = 0; j < i; ++j) {
        if (panes[i].pane_id == panes[j].pane_id) {
          throw EncodingError{"Duplicate pane identity"};
        }
      }
    }
  }

  void TabClosed::validate() const {
    validateWorkspaceClosure(location.workspace, workspace_closed, previous_workspace);
  }

  void ResyncRequired::validate() const {
    validateWorkspaceClosure(workspace, workspace_closed, previous_workspace);
  }

  void ClientLayoutSnapshot::validate() const {
    if (!restored) {
      if (sidebar_width != 0 || active_tab || !tabs.empty()) {
        throw EncodingError{"Invalid empty layout"};
      }
    } else {
      if (sidebar_width == 0) {
        throw EncodingError{"Invalid sidebar width"};
      }

      validateLayoutCollection(active_tab, tabs);
    }
  }

  void PaneFocusCommand::validate() const {
    if (pane_generation == 0) {
      throw EncodingError{"Invalid pane generation"};
    }
  }

  void PaneFocusResult::validate() const {
    if (outcome == PaneFocusOutcome::focused && focused_pane_id == 0) {
      throw EncodingError{"Missing focused pane"};
    }
  }

}
}
