export module telar.gui.presentation.client_view_state;

import std;

import telar.gui.presentation.display_metrics;

// Interface: application/client_view_state.cppm
export {
  namespace telar::gui {

    struct ClientViewState {
      bool sidebar_visible = true;
      std::uint16_t sidebar_width = SidebarColumns::minimum_width;
      bool workspace_list_collapsed = false;
      bool pane_gaps = true;
      std::string_view window_title;
    };

  }
}
