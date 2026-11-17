module telar.gui.foundation.forms;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

namespace telar::gui::inline foundation::inline forms {

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
