export module telar.gui.foundation.forms:history_match_highlight;

import std;

import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

// Interface: presentation/history_match_highlight.cppm
export {
  namespace telar::gui::inline foundation::inline forms {

    template <typename Sink>
    concept HistoryMatchSink = requires(Sink& sink, Rect bounds, std::string_view text) {
      { sink(bounds, text) } -> std::same_as<void>;
    };

    // A run of a command's bytes that a search matched.
    struct HistoryMatchRange {
      std::uint32_t offset = 0;
      std::uint32_t length = 0;

      bool operator==(const HistoryMatchRange&) const = default;
    };

    // Where a search matched one command, as runs of its bytes in order, the one highlight every
    // surface that lists the history draws. `find` asks the runtime's matcher; ranges the runtime
    // sends replace them through `append`.
    class HistoryMatchRanges {
    public:
      // A command's matches past this many runs are not drawn.
      static constexpr std::size_t capacity = 64;

      // What the runtime's matcher (runtime::historyMatch) covers of `command` for `query`: fzf's
      // FuzzyMatchV2 with its extended syntax and smart case. None when it does not match.
      [[nodiscard]] static HistoryMatchRanges find(std::string_view command, std::string_view query);

      // Adds the run after the last one, joining it when they touch; a run past the capacity, or
      // before the last one, is left out.
      void append(HistoryMatchRange range) noexcept;

      [[nodiscard]] std::span<const HistoryMatchRange> view() const noexcept;

      // Whether any byte of [offset, offset + length) of the command was matched.
      [[nodiscard]] bool covers(std::size_t offset, std::size_t length) const noexcept;

      bool operator==(const HistoryMatchRanges& other) const noexcept;

    private:
      ds::Array<HistoryMatchRange, capacity> ranges_{};
      std::size_t count_ = 0;
    };

    class HistoryMatchHighlight {
    public:
      explicit HistoryMatchHighlight(const HistoryMatchRanges& ranges) noexcept;

      [[nodiscard]] std::size_t matched() const noexcept;

      // Hands `sink` each visible cluster of `text`, which lies at byte `offset` of the command the
      // ranges are of, that holds a matched byte. Generic over the caller's sink, so it stays
      // here; it runs per history row painted.
      template <HistoryMatchSink Sink>
      [[tbc::generic]] void paint(std::string_view text, std::size_t offset, Rect bounds, float cell_width, Sink& sink) {
        GraphemeCursor cursor{text};
        std::uint32_t column = 0;

        while (static_cast<float>(column) * cell_width < bounds.width) {
          const auto start = cursor.position();
          const auto cluster = cursor.nextReplacingInvalid();
          if (!cluster) {
            break;
          }

          const auto width = static_cast<float>(cursor.columns()) * cell_width;
          const auto x = static_cast<float>(column) * cell_width;
          if (x + width > bounds.width) {
            break;
          }

          // A replaced invalid byte is one byte of the text, whatever the cluster drawn for it.
          const auto bytes = cursor.position() - start;
          if (ranges_->covers(offset + start, bytes)) {
            sink({.x = bounds.x + x, .y = bounds.y, .width = width, .height = bounds.height}, *cluster);
            matched_ += bytes;
          }

          column += cursor.columns();
        }
      }

    private:
      const HistoryMatchRanges* ranges_;
      std::size_t matched_ = 0;
    };

  }
}
