module telar.gui.foundation.forms;

import std;
import telar.gui.foundation.terminal;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

namespace telar::gui::inline foundation::inline forms {

  FormFieldGeometry FormFieldGeometry::derive(Rect bounds, ChromeMetrics chrome, const FontGrid& grid) noexcept {
    FormFieldGeometry result;

    if (bounds.empty()) {
      return result;
    }

    result.content = bounds;
    const auto inset = std::min(chrome.px(horizontal_padding), bounds.width / 4);

    result.content.x += inset;
    result.content.width = std::max(0.0F, bounds.width - (2 * inset));
    result.content.height = std::min(static_cast<float>(grid.height), bounds.height - std::min(chrome.px(vertical_padding), bounds.height / 3));
    result.content.y += std::floor((bounds.height - result.content.height) / 2);
    result.cell_width = grid.width;
    result.line_height = grid.height;
    result.insertion_width = std::min(std::max(caret_width, chrome.px(caret_width)), result.content.width);
    if (!result.content.empty()) {
      result.columns = static_cast<std::uint16_t>(std::min(static_cast<float>(std::numeric_limits<std::uint16_t>::max()), std::max(1.0F, std::floor(result.content.width / result.cell_width))));
    }

    return result;
  }

  Rect FormFieldGeometry::caret(std::uint16_t column) const noexcept {
    if (columns == 0) {
      return {};
    }

    return {.x = content.x + (static_cast<float>(std::min(column, static_cast<std::uint16_t>(columns - 1))) * cell_width), .y = content.y, .width = insertion_width, .height = content.height};
  }

  FormFieldGeometry FormFieldGeometry::terminal(Rect bounds, const FontGrid& grid) noexcept {
    FormFieldGeometry result;

    if (bounds.empty()) {
      return result;
    }

    result.content = bounds;
    result.cell_width = grid.width;
    result.line_height = grid.height;
    result.insertion_width = std::min(result.cell_width, bounds.width);
    result.columns = static_cast<std::uint16_t>(std::min(static_cast<float>(std::numeric_limits<std::uint16_t>::max()), std::max(1.0F, std::floor(bounds.width / result.cell_width))));

    return result;
  }

  Rect FormFieldGeometry::selection(EditorColumns selected) const noexcept {
    const auto first = std::min(selected.first, columns);
    const auto last = std::max(first, std::min(selected.last, columns));

    return {.x = content.x + (static_cast<float>(first) * cell_width), .y = content.y, .width = static_cast<float>(last - first) * cell_width, .height = content.height};
  }

  Rect FormFieldGeometry::underline(std::uint32_t text_columns) const noexcept {
    const auto visible_columns = std::min(static_cast<float>(text_columns), std::floor(content.width / cell_width));
    const auto top = std::floor(content.y + ((content.height - line_height) / 2)) + line_height - underline_offset;
    const auto clipped_top = std::max(content.y, top);

    return {.x = content.x, .y = clipped_top, .width = visible_columns * cell_width, .height = std::max(0.0F, std::min(top + underline_height, content.bottom()) - clipped_top)};
  }

}
