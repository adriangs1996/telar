#pragma once

#include "atomic_frame.hpp"
#include <algorithm>
#include <array>

namespace telar::runtime {

template <typename Source>
concept AtomicFrameSource = requires(Source &source, const AtomicFrameResource &resource) {
  { source.available(resource) } -> std::same_as<bool>;
  { source.release(resource) } -> std::same_as<void>;
};

template <typename Sink>
concept AtomicFrameSink = requires(Sink &sink, std::span<const std::uint8_t> bytes, const AtomicFrameView &frame) {
  { sink.output(bytes) } -> std::same_as<void>;
  { sink.atomicFrame(frame) } -> std::same_as<bool>;
};

class AtomicFrameFilter {
public:
  struct Statistics {
    std::uint64_t discarded = 0;
    std::uint64_t unavailable = 0;
    std::uint64_t forwarded = 0;
    std::uint64_t direct = 0;
    std::uint64_t file = 0;
  };

  template <AtomicFrameSource Source, AtomicFrameSink Sink>
  static Statistics feed(std::span<const std::uint8_t> bytes, std::size_t storage_limit, Source &source, Sink &sink) {
    const std::string_view text{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    std::size_t emitted = 0;
    std::size_t search_from = 0;
    Statistics statistics;
    while (const auto first = AtomicFrame::find(text, search_from)) {
      std::array<SelectedFrame, maximum_placements> selected;
      std::size_t count = 0;
      auto end = first->end;
      bool overflow = !record(selected, count, *first);
      while (const auto frame = AtomicFrame::at(text, end)) {
        overflow |= !record(selected, count, *frame);
        end = frame->end;
      }

      if (!overflow) {
        auto entries = std::span{selected}.first(count);
        for (auto &entry : entries) {
          for (auto recent = entry.recent_count; recent != 0; --recent) {
            const auto frame = AtomicFrame::at(text, entry.recent[recent - 1]).value();
            if (source.available(resource(frame, storage_limit))) {
              entry.selected = frame.start;
              break;
            }
          }
        }

        output(bytes.subspan(emitted, first->start - emitted), sink);
        auto position = first->start;
        while (position < end) {
          const auto frame = AtomicFrame::at(text, position).value();
          const auto selected = selectedStart(entries, frame.control.key);
          if (selected == frame.start) {
            const AtomicFrameView view{bytes.subspan(frame.start, frame.end - frame.start), frame.command_start - frame.start, frame.command_end - frame.start, frame.encoded_name, frame.control};
            if (sink.atomicFrame(view)) {
              ++statistics.direct;
              statistics.file += frame.control.medium == GraphicsInputMedium::file;
              ++statistics.forwarded;
            } else if (frame.control.medium == GraphicsInputMedium::file) {
              ++statistics.unavailable;
            } else {
              sink.output(view.bytes);
              ++statistics.forwarded;
            }
          } else {
            source.release(resource(frame, storage_limit));
            if (frame.cursor_wrapped) {
              // DECSC still updates the saved cursor when its replacement frame is discarded.
              sink.output({reinterpret_cast<const std::uint8_t *>(AtomicFrame::cursor_save.data()), AtomicFrame::cursor_save.size()});
            }
            statistics.unavailable += !selected.has_value();
            statistics.discarded += selected.has_value();
          }
          position = frame.end;
        }
        emitted = end;
      }
      search_from = end;
    }

    output(bytes.subspan(emitted), sink);
    return statistics;
  }

private:
  static constexpr std::size_t maximum_placements = 256;
  static constexpr std::size_t recent_frames = 8;

  struct SelectedFrame {
    AtomicFrameKey key;
    std::array<std::size_t, recent_frames> recent;
    std::size_t recent_count;
    std::optional<std::size_t> selected;
  };

  static bool record(std::span<SelectedFrame> entries, std::size_t &count, const AtomicFrame &frame) noexcept {
    for (auto &entry : entries.first(count)) {
      if (entry.key != frame.control.key) {
        continue;
      }

      if (entry.recent_count == entry.recent.size()) {
        std::move(entry.recent.begin() + 1, entry.recent.end(), entry.recent.begin());
        --entry.recent_count;
      }
      entry.recent[entry.recent_count++] = frame.start;
      return true;
    }

    if (count == entries.size()) {
      return false;
    }
    auto &entry = entries[count++];
    entry.key = frame.control.key;
    entry.recent[0] = frame.start;
    entry.recent_count = 1;
    entry.selected.reset();
    return true;
  }

  static std::optional<std::size_t> selectedStart(std::span<const SelectedFrame> entries, AtomicFrameKey key) noexcept {
    for (const auto &entry : entries) {
      if (entry.key == key) {
        return entry.selected;
      }
    }
    return std::nullopt;
  }

  static AtomicFrameResource resource(const AtomicFrame &frame, std::size_t storage_limit) noexcept {
    return {frame.encoded_name, frame.control.byte_count, storage_limit, frame.control.medium};
  }

  template <AtomicFrameSink Sink>
  static void output(std::span<const std::uint8_t> bytes, Sink &sink) {
    if (!bytes.empty()) {
      sink.output(bytes);
    }
  }
};

}
