module telar.gui.features.status_bar;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;

namespace telar::gui::features::status_bar {

  ModeBarGeometry ModeBarGeometry::derive(Rect area, ChromeMetrics chrome, const ModeBarMeasurements& measured) noexcept {
    ModeBarGeometry result;

    if (area.empty()) {
      return result;
    }

    const auto height = HistoryHintGeometry::keyHeight(chrome, area.height);

    result.title = {.x = area.x, .y = area.y + std::floor((area.height - height) / 2), .width = std::min(measured.title, area.width), .height = height};
    auto x = result.title.right() + chrome.px(title_gap);
    const auto available = std::min(measured.count, measured.hints.size());

    for (std::size_t index = 0; index < available; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.hints[index]);
      if (x + width > area.right()) {
        break;
      }

      result.hints.atMut(index) = HistoryHintGeometry::derive({.x = x, .y = area.y, .width = width, .height = area.height}, chrome, measured.hints[index]);
      ++result.count;
      x += width + chrome.px(hint_gap);
    }

    return result;
  }

}
