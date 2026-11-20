module telar.gui.application;

import std;

import telar.gui.features.terminal.input;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;

namespace telar::gui::application::terminal::input {

  void showTop(Session& session, std::uint64_t pane_id, ds::Option<std::uint64_t> top) noexcept {
    if (auto* pane = session.findPaneMut(pane_id)) {
      pane->shown_top = top;
    }
  }

  void releaseRows(Session& session, std::uint64_t pane_id) {
    if (auto* pane = session.findPaneMut(pane_id); pane != nullptr && pane->folds.empty()) {
      pane->rows.release();
    }
  }

  void scroll(Session& session, ScrollDirection direction) {
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    if (pane == nullptr || !pane->attached || pane->exited) {
      return;
    }

    const auto pane_id = pane->id;

    switch (wheelRoute(pane->screen)) {
    case WheelRoute::report: {
      MouseEncoder encoder;

      session.input(pane_id, encoder.encode(direction == ScrollDirection::up ? MouseEncoder::wheel_up : MouseEncoder::wheel_down, 1, 1, false, true), PaneInputSource::mouse);
      return;
    }
    case WheelRoute::keys: {
      KeyEncoder encoder;
      const auto bytes = encoder.alternateScroll(direction == ScrollDirection::up, pane->screen.modes());

      for (std::int32_t step = 0; step < WheelAccumulator::rows_per_line; ++step) {
        session.input(pane_id, bytes, PaneInputSource::mouse);
      }

      return;
    }
    case WheelRoute::scroll:
      session.scroll({.pane_id = pane->id, .rows = direction == ScrollDirection::up ? WheelAccumulator::rows_per_line : -WheelAccumulator::rows_per_line});
      return;
    }
  }

}
