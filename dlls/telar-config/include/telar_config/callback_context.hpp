#pragma once

#include <cstdint>

namespace telar::runtime::config {

struct BindingContext {
  bool sidebar_visible = true;
  std::uint16_t tab_count = 0;
  std::uint16_t active_tab_index = 0;
  std::uint16_t pane_count = 0;
  std::uint64_t focused_pane_id = 0;
};

}
