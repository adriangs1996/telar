module telar.gui.foundation.forms;

import std;

import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline forms {

  NamePromptGeometry NamePromptGeometry::measure(CellRectangle host, CellRectangle wanted) noexcept {
    const auto margin_x = host.width > horizontal_threshold ? horizontal_margin : 0;
    const auto margin_y = host.height > vertical_threshold ? vertical_margin : 0;
    const auto width = std::min(wanted.width, static_cast<std::uint16_t>(host.width - (margin_x * 2)));
    const auto height = std::min(wanted.height, static_cast<std::uint16_t>(host.height - (margin_y * 2)));
    NamePromptGeometry result;

    result.bounds = {.x = coordinate(static_cast<std::uint32_t>(host.x) + ((host.width - width) / 2)), .y = coordinate(static_cast<std::uint32_t>(host.y) + ((host.height - height) / 2)), .width = width, .height = height};
    const auto content = width > 2 && height > 2 ? result.bounds.inner(1) : result.bounds;

    if (width > 4) {
      result.title = {.x = coordinate(static_cast<std::uint32_t>(result.bounds.x) + 2), .y = result.bounds.y, .width = static_cast<std::uint16_t>(width - 4), .height = 1};
    }

    result.field = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + (content.height > 2 ? 1 : 0)), .width = content.width, .height = std::min<std::uint16_t>(1, content.height)};
    if (content.height > 2) {
      result.footer = {.x = content.x, .y = coordinate(static_cast<std::uint32_t>(content.y) + content.height - 1), .width = content.width, .height = 1};
    }

    return result;
  }

  std::uint16_t NamePromptGeometry::coordinate(std::uint32_t value) noexcept {
    return static_cast<std::uint16_t>(std::min<std::uint32_t>(value, std::numeric_limits<std::uint16_t>::max()));
  }

}
