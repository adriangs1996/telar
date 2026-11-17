module telar.gui.presentation.form_field_geometry;

import std;
import telar.gui.foundation.terminal;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

namespace telar::gui {

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

  HistoryMatchHighlight::HistoryMatchHighlight(std::string_view query) noexcept
      : query_(query) {}

  std::size_t HistoryMatchHighlight::matched() const noexcept {
    return matched_;
  }

  PathPickerPlacement PathPickerPlacement::forPage(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t count) noexcept {
    const auto rows = std::max<std::uint16_t>(1, std::min(count, maximum_rows));

    return place(host, cursor, maximum_width, static_cast<std::uint16_t>(rows + chrome_rows));
  }

  PathPickerPlacement PathPickerPlacement::place(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t requested_width, std::uint16_t requested_height) noexcept {
    const auto width = std::min(requested_width, host.width);
    const auto height = std::min(requested_height, host.height);

    if (!cursor) {
      return {.area = {.x = static_cast<std::uint16_t>(host.x + ((host.width - width) / 2)), .y = static_cast<std::uint16_t>(host.y + ((host.height - height) / fallback_vertical_divisor)), .width = width, .height = height}};
    }

    const auto left = cursor->x > cursor_inset ? cursor->x - cursor_inset : 0;
    const auto x = std::min<unsigned>(left, host.x + host.width - width);
    const auto host_bottom = static_cast<unsigned>(host.y) + host.height;
    const auto next_row = static_cast<unsigned>(cursor->y) + 1;
    const auto below = host_bottom > next_row ? host_bottom - next_row : 0;
    const auto above = cursor->y > host.y ? cursor->y - host.y : 0;
    const auto flipped = below < height && above > below;
    const auto room = flipped ? above : below;
    const auto fitted = static_cast<std::uint16_t>(std::min<unsigned>(height, room));

    return {
        .area = {.x = static_cast<std::uint16_t>(std::max<unsigned>(x, host.x)), .y = static_cast<std::uint16_t>(flipped ? cursor->y - fitted : next_row), .width = width, .height = fitted},
        .flipped = flipped,
    };
  }

  PathPickerGeometry PathPickerGeometry::measure(PathPickerPlacement placement, std::size_t total, std::size_t selection, PathPickerFieldColumns columns) noexcept {
    PathPickerGeometry result;
    const auto content = placement.area.inner(1);
    constexpr std::uint16_t field_and_footer_rows = 2;
    if (content.height <= field_and_footer_rows) {
      return result;
    }

    auto field = content;

    field.y = placement.flipped ? static_cast<std::uint16_t>(content.y + content.height - 1) : content.y;
    field.height = 1;
    result.footer = field;
    result.footer.y = placement.flipped ? content.y : static_cast<std::uint16_t>(content.y + content.height - 1);
    const auto count_columns = std::min<std::uint16_t>(columns.count, field.width / 4);
    const auto count_room = std::min<std::uint16_t>(field.width, static_cast<std::uint16_t>(count_columns + 1));
    const auto field_columns = static_cast<std::uint16_t>(field.width - count_room);
    const auto count_inset = std::min<std::uint16_t>(1, count_room);

    result.count_label = {.x = static_cast<std::uint16_t>(field.x + field_columns + count_inset), .y = field.y, .width = static_cast<std::uint16_t>(count_room - count_inset), .height = 1};
    const auto root_columns = std::min<std::uint16_t>(static_cast<std::uint16_t>(columns.root + 1), field_columns / 2);

    result.root_label = {.x = field.x, .y = field.y, .width = root_columns, .height = 1};
    result.query = {.x = static_cast<std::uint16_t>(field.x + root_columns), .y = field.y, .width = static_cast<std::uint16_t>(field_columns - root_columns), .height = 1};

    const auto row_area = CellRectangle{.x = content.x, .y = static_cast<std::uint16_t>(content.y + 1), .width = content.width, .height = static_cast<std::uint16_t>(content.height - field_and_footer_rows)};
    const auto count = std::min<std::size_t>({row_area.height, total, result.rows.size()});
    const auto selected = total == 0 ? 0 : std::min(selection, total - 1);
    const auto first = selected + 1 > count ? selected + 1 - count : 0;

    result.empty = {.x = static_cast<std::uint16_t>(row_area.x + std::min<std::uint16_t>(2, row_area.width)), .y = placement.flipped ? static_cast<std::uint16_t>(row_area.y + row_area.height - 1) : row_area.y, .width = static_cast<std::uint16_t>(row_area.width - std::min<std::uint16_t>(2, row_area.width)), .height = 1};
    for (std::size_t offset = 0; offset < count; ++offset) {
      const auto row = placement.flipped ? row_area.height - 1 - offset : offset;

      result.rows[offset] = {.bounds = {.x = row_area.x, .y = static_cast<std::uint16_t>(row_area.y + row), .width = row_area.width, .height = 1}, .index = first + offset};
    }

    result.row_count = count;

    return result;
  }

  SuggestionPreview::SuggestionPreview(std::string_view text, Rect bounds, const FontGrid& grid)
      : bounds_(bounds),
        line_height_(std::max<std::uint16_t>(1, grid.height)),
        y_(bounds.y),
        lines_(text, columns(bounds, grid.width)) {}

  std::optional<SuggestionPreviewLine> SuggestionPreview::next() {
    if (finished_ || y_ + line_height_ > bounds_.bottom()) {
      return std::nullopt;
    }

    const auto line = lines_.next();
    if (!line) {
      return std::nullopt;
    }

    const Rect row{.x = bounds_.x, .y = y_, .width = bounds_.width, .height = line_height_};

    y_ += line_height_;
    if (y_ + line_height_ > bounds_.bottom() && lines_.next()) {
      finished_ = true;

      return SuggestionPreviewLine{.text = shortened_message, .bounds = row, .shortened = true};
    }

    return SuggestionPreviewLine{.text = *line, .bounds = row};
  }

  std::uint16_t SuggestionPreview::columns(Rect bounds, std::uint16_t width) {
    return static_cast<std::uint16_t>(std::clamp(std::floor(bounds.width / static_cast<float>(std::max<std::uint16_t>(1, width))), 1.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
  }

}
