module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.forms:history_match_highlight;

import std;

import telar.base.text;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

// Interface: presentation/history_match_highlight.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    template <typename Sink>
    concept HistoryMatchSink = requires(Sink& sink, Rect bounds, std::string_view text) {
      { sink(bounds, text) } -> std::same_as<void>;
    };

    class HistoryMatchHighlight {
    public:
      explicit HistoryMatchHighlight(std::string_view query) noexcept;

      [[nodiscard]] std::size_t matched() const noexcept;

      // Generic over the caller's sink, so it stays here; it runs per history row painted.
      template <HistoryMatchSink Sink>
      TBC_GENERIC void paint(std::string_view text, Rect bounds, float cell_width, Sink& sink) {
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
}
