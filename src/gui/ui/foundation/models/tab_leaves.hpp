#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>

#pragma once

import telar.gui.model.records;

namespace telar::gui::qt {

  // Calls `visit` with each pane leaf of `tab` in layout order; with `shown`, only the leaves the
  // tab shows: the focused one alone when it is fullscreen.
  template <Allocator Memory, typename Visit>
  void forEachLeaf(const Tab<Memory>& tab, bool shown, Visit&& visit) {
    for (const auto& node : tab.layout.nodes()) {
      const auto* leaf = std::get_if<ClientLayoutPane>(&node);
      if (leaf != nullptr && (!shown || !tab.fullscreen || leaf->pane_id == tab.focused_pane)) {
        visit(*leaf);
      }
    }
  }

}
