#pragma once

#include "presentation/sidebar_columns.hpp"
#include <cstdint>
#include <string_view>

namespace telar::gui {

struct ClientViewState {
  bool sidebar_visible = true;
  std::uint16_t sidebar_width = SidebarColumns::minimum_width;
  bool workspace_list_collapsed = false;
  bool pane_gaps = true;
  std::string_view window_title;
};

}
