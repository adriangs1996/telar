#pragma once

#include "core/geometry.hpp"
#include "telar_base/text/ascii.hpp"
#include "text/grapheme_cursor.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

template <typename Sink>
concept HistoryMatchSink = requires(Sink &sink, Rect bounds, std::string_view text) {
  { sink(bounds, text) } -> std::same_as<void>;
};

class HistoryMatchHighlight {
public:
  explicit HistoryMatchHighlight(std::string_view query) noexcept
      : query_(query) {}

  [[nodiscard]] std::size_t matched() const noexcept {
    return matched_;
  }

  template <HistoryMatchSink Sink>
  void paint(std::string_view text, Rect bounds, float cell_width, Sink &sink) {
    GraphemeCursor cursor{text};
    std::uint32_t column = 0;
    while (static_cast<float>(column) * cell_width < bounds.width && matched_ < query_.size()) {
      const auto cluster = cursor.nextReplacingInvalid();
      if (!cluster) {
        break;
      }

      const auto width = static_cast<float>(cursor.columns()) * cell_width;
      const auto x = static_cast<float>(column) * cell_width;
      if (x + width > bounds.width) {
        break;
      }

      if (cluster->size() <= query_.size() - matched_ && runtime::asciiEqualIgnoreCase(*cluster, query_.substr(matched_, cluster->size()))) {
        sink({.x = bounds.x + x, .y = bounds.y, .width = width, .height = bounds.height}, *cluster);
        matched_ += cluster->size();
      }

      column += cursor.columns();
    }
  }

private:
  std::string_view query_;
  std::size_t matched_ = 0;
};

}
