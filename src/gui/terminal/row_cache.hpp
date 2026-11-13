#pragma once

#include "core/memory.hpp"
#include "terminal/screen.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

// Rows of a pane's scrollback the runtime sent apart from its screen, by stable number: the
// rows a scrolled or folded view shows beyond the screen it holds. A fixed number of slots, a
// row in the slot of its number modulo the slots, so a newer row replaces an older one there.
// The slots are allocated on the first row stored and released by `release`.
template <Allocator Memory>
class RowCache {
public:
  static constexpr std::size_t slot_count = 512;
  // Requests in flight at once, each for at most `request_rows` rows.
  static constexpr std::size_t maximum_pending = 4;
  static constexpr std::uint16_t request_rows = 128;

  // Past this many bytes of link targets, those of rows no longer held are dropped.
  static constexpr std::size_t uri_compaction_bytes = std::size_t{256} * 1024;

  struct Row {
    std::span<const CellValue> cells;
    Byte flags = 0;
    // Changes whenever the slot holds another row, for a painter that caches what it drew.
    std::uint64_t revision = 0;
  };

  // A hyperlink on a held row: the cells from `column` on that it covers, and its target.
  struct Link {
    std::uint64_t stable = 0;
    std::uint16_t column = 0;
    std::uint32_t length = 0;
    std::uint32_t uri_offset = 0;
    std::uint16_t uri_length = 0;
  };

  explicit RowCache(Memory &memory)
      : cells_(AllocatorRef<CellValue, Memory>{memory}),
        slots_(AllocatorRef<Slot, Memory>{memory}),
        links_(AllocatorRef<Link, Memory>{memory}),
        uris_(AllocatorRef<Byte, Memory>{memory}) {}

  // The rows' numbering: rows of another generation are forgotten, as are requests for them.
  void number(std::uint64_t generation) {
    if (generation != generation_) {
      generation_ = generation;
      forget();
    }
  }

  [[nodiscard]] std::uint64_t generation() const noexcept {
    return generation_;
  }

  // Keeps the rows of `reply`, when they are numbered as the cache numbers rows and as wide
  // as `columns`. Whether any were kept.
  bool store(const PaneRows &reply, std::uint16_t columns) {
    settle(reply.request_id);
    if (reply.generation != generation_ || reply.rows == 0 || reply.cols != columns || columns == 0) {
      return false;
    }
    if (columns_ != columns) {
      forget();
      columns_ = columns;
    }
    if (slots_.empty()) {
      slots_.resize(slot_count);
      cells_.resize(slot_count * columns_);
    }

    auto reader = reply.reader();
    for (std::uint16_t row = 0; row < reply.rows; ++row) {
      const auto stable = reply.from + row;
      auto &slot = slots_[stable % slot_count];
      if (slot.held) {
        dropLinks(slot.stable);
      }
      slot.stable = stable;
      slot.flags = reply.text_metadata ? reply.text_metadata->row_flags[row] : Byte{0};
      slot.revision = ++revision_;
      slot.held = true;
      const auto first = (stable % slot_count) * columns_;
      for (std::uint16_t column = 0; column < columns_; ++column) {
        const auto cell = reader.next();
        cells_[first + column] = cell ? CellValue{*cell} : CellValue{};
      }
    }
    if (reply.text_metadata) {
      keepLinks(reply, *reply.text_metadata);
    }

    return true;
  }

  // A hyperlink on a held row as `links` shows it.
  struct LinkView {
    std::uint16_t column = 0;
    std::uint32_t length = 0;
    std::string_view uri;
  };

  // Calls `visit` with each hyperlink on held row `stable`.
  template <typename Visitor>
  void links(std::uint64_t stable, Visitor &&visit) const {
    if (!holds(stable)) {
      return;
    }
    for (const auto &link : links_) {
      if (link.stable == stable) {
        visit(LinkView{.column = link.column, .length = link.length, .uri = textView(std::span{uris_}.subspan(link.uri_offset, link.uri_length))});
      }
    }
  }

  [[nodiscard]] std::optional<Row> find(std::uint64_t stable) const noexcept {
    if (slots_.empty()) {
      return std::nullopt;
    }
    const auto index = stable % slot_count;
    const auto &slot = slots_[index];
    if (!slot.held || slot.stable != stable) {
      return std::nullopt;
    }

    return Row{.cells = std::span<const CellValue>{cells_}.subspan(index * columns_, columns_), .flags = slot.flags, .revision = slot.revision};
  }

  [[nodiscard]] bool holds(std::uint64_t stable) const noexcept {
    return find(stable).has_value();
  }

  // The first of the rows from `first` to `last` neither held nor asked for, if any: the next
  // request starts there.
  [[nodiscard]] std::optional<std::uint64_t> missing(std::uint64_t first, std::uint64_t last) const noexcept {
    for (auto stable = first; stable <= last; ++stable) {
      if (!holds(stable) && !asked(stable)) {
        return stable;
      }
    }
    return std::nullopt;
  }

  [[nodiscard]] bool full() const noexcept {
    return std::ranges::all_of(pending_, [](const Pending &request) { return request.id != 0; });
  }

  // A request for the rows from `from`, in flight until its reply or its failure settles it.
  void ask(std::uint64_t request_id, std::uint64_t from, std::uint16_t count) noexcept {
    for (auto &request : pending_) {
      if (request.id == 0) {
        request = {.id = request_id, .from = from, .count = count};
        return;
      }
    }
  }

  // Whether `request_id` is one of the cache's, which it no longer waits for.
  bool settle(std::uint64_t request_id) noexcept {
    for (auto &request : pending_) {
      if (request.id == request_id && request_id != 0) {
        request = {};
        return true;
      }
    }
    return false;
  }

  // Forgets every row and request, and gives the slots back.
  void release() {
    forget();
    Vector<Slot, Memory> slots{slots_.get_allocator()};
    slots_.swap(slots);
    Vector<CellValue, Memory> cells{cells_.get_allocator()};
    cells_.swap(cells);
    Vector<Link, Memory> links{links_.get_allocator()};
    links_.swap(links);
    Vector<Byte, Memory> uris{uris_.get_allocator()};
    uris_.swap(uris);
  }

  [[nodiscard]] bool empty() const noexcept {
    return slots_.empty();
  }

private:
  struct Slot {
    std::uint64_t stable = 0;
    std::uint64_t revision = 0;
    Byte flags = 0;
    bool held = false;
  };

  struct Pending {
    std::uint64_t id = 0;
    std::uint64_t from = 0;
    std::uint16_t count = 0;
  };

  [[nodiscard]] bool asked(std::uint64_t stable) const noexcept {
    return std::ranges::any_of(pending_, [stable](const Pending &request) { return request.id != 0 && stable >= request.from && stable < request.from + request.count; });
  }

  void forget() noexcept {
    for (auto &slot : slots_) {
      slot.held = false;
    }
    pending_ = {};
    links_.clear();
    uris_.clear();
  }

  void dropLinks(std::uint64_t stable) noexcept {
    std::erase_if(links_, [stable](const Link &link) { return link.stable == stable; });
  }

  // The reply's hyperlinks by the row they are on, with copies of their targets.
  void keepLinks(const PaneRows &reply, const TextMetadata &metadata) {
    if (metadata.runs.empty()) {
      return;
    }
    if (uris_.size() > uri_compaction_bytes) {
      compactUris();
    }
    for (const auto &run : metadata.runs) {
      if (run.link_index >= metadata.links.size() || reply.cols == 0) {
        continue;
      }
      const auto &target = metadata.links[run.link_index];
      const auto offset = uris_.size();
      uris_.insert(uris_.end(), metadata.uris.begin() + target.offset, metadata.uris.begin() + target.offset + target.len);
      links_.push_back({.stable = reply.from + (run.start / reply.cols), .column = static_cast<std::uint16_t>(run.start % reply.cols), .length = run.len, .uri_offset = static_cast<std::uint32_t>(offset), .uri_length = target.len});
    }
  }

  // Keeps only the targets of links still held.
  void compactUris() {
    Vector<Byte, Memory> kept{uris_.get_allocator()};
    for (auto &link : links_) {
      const auto offset = kept.size();
      kept.insert(kept.end(), uris_.begin() + link.uri_offset, uris_.begin() + link.uri_offset + link.uri_length);
      link.uri_offset = static_cast<std::uint32_t>(offset);
    }
    uris_.swap(kept);
  }

  Vector<CellValue, Memory> cells_;
  Vector<Slot, Memory> slots_;
  Vector<Link, Memory> links_;
  Vector<Byte, Memory> uris_;
  std::array<Pending, maximum_pending> pending_{};
  std::uint64_t generation_ = 0;
  std::uint64_t revision_ = 0;
  std::uint16_t columns_ = 0;
};

}
