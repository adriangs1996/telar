module telar.gui.foundation.terminal;

import std;

import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::inline foundation::inline terminal {

  template <Allocator Memory>
  RowCache<Memory>::RowCache(Memory& memory)
      : cells_(AllocatorRef<CellValue, Memory>{memory}),
        slots_(AllocatorRef<Slot, Memory>{memory}),
        links_(AllocatorRef<Link, Memory>{memory}),
        uris_(AllocatorRef<Byte, Memory>{memory}) {}

  template <Allocator Memory>
  void RowCache<Memory>::number(std::uint64_t generation) {
    if (generation != generation_) {
      generation_ = generation;
      forget();
    }
  }

  template <Allocator Memory>
  std::uint64_t RowCache<Memory>::generation() const noexcept {
    return generation_;
  }

  template <Allocator Memory>
  bool RowCache<Memory>::store(const PaneRows& reply, std::uint16_t columns) {
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
      auto& slot = slots_[stable % slot_count];
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

  template <Allocator Memory>
  auto RowCache<Memory>::find(std::uint64_t stable) const noexcept -> ds::Option<Row> {
    if (slots_.empty()) {
      return ds::none;
    }

    const auto index = stable % slot_count;
    const auto& slot = slots_[index];
    if (!slot.held || slot.stable != stable) {
      return ds::none;
    }

    return Row{.cells = std::span<const CellValue>{cells_}.subspan(index * columns_, columns_), .flags = slot.flags, .revision = slot.revision};
  }

  template <Allocator Memory>
  bool RowCache<Memory>::holds(std::uint64_t stable) const noexcept {
    return find(stable).hasValue();
  }

  template <Allocator Memory>
  ds::Option<std::uint64_t> RowCache<Memory>::missing(std::uint64_t first, std::uint64_t last) const noexcept {
    for (auto stable = first; stable <= last; ++stable) {
      if (!holds(stable) && !asked(stable)) {
        return stable;
      }
    }

    return ds::none;
  }

  template <Allocator Memory>
  bool RowCache<Memory>::full() const noexcept {
    return std::ranges::all_of(pending_, [](const Pending& request) {
      return request.id != 0;
    });
  }

  template <Allocator Memory>
  void RowCache<Memory>::ask(std::uint64_t request_id, std::uint64_t from, std::uint16_t count) noexcept {
    for (auto& request : pending_) {
      if (request.id == 0) {
        request = {.id = request_id, .from = from, .count = count};
        return;
      }
    }
  }

  template <Allocator Memory>
  bool RowCache<Memory>::settle(std::uint64_t request_id) noexcept {
    for (auto& request : pending_) {
      if (request.id == request_id && request_id != 0) {
        request = {};
        return true;
      }
    }

    return false;
  }

  template <Allocator Memory>
  void RowCache<Memory>::release() {
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

  template <Allocator Memory>
  bool RowCache<Memory>::empty() const noexcept {
    return slots_.empty();
  }

  template <Allocator Memory>
  bool RowCache<Memory>::asked(std::uint64_t stable) const noexcept {
    return std::ranges::any_of(pending_, [stable](const Pending& request) {
      return request.id != 0 && stable >= request.from && stable < request.from + request.count;
    });
  }

  template <Allocator Memory>
  void RowCache<Memory>::forget() noexcept {
    for (auto& slot : slots_) {
      slot.held = false;
    }

    pending_ = {};
    links_.clear();
    uris_.clear();
  }

  template <Allocator Memory>
  void RowCache<Memory>::dropLinks(std::uint64_t stable) noexcept {
    std::erase_if(links_, [stable](const Link& link) {
      return link.stable == stable;
    });
  }

  template <Allocator Memory>
  void RowCache<Memory>::keepLinks(const PaneRows& reply, const TextMetadata& metadata) {
    if (metadata.runs.empty()) {
      return;
    }

    if (uris_.size() > uri_compaction_bytes) {
      compactUris();
    }

    for (const auto& run : metadata.runs) {
      if (run.link_index >= metadata.links.size() || reply.cols == 0) {
        continue;
      }

      const auto& target = metadata.links[run.link_index];
      const auto offset = uris_.size();

      uris_.insert(uris_.end(), metadata.uris.begin() + target.offset, metadata.uris.begin() + target.offset + target.len);
      links_.push_back({.stable = reply.from + (run.start / reply.cols), .column = static_cast<std::uint16_t>(run.start % reply.cols), .length = run.len, .uri_offset = static_cast<std::uint32_t>(offset), .uri_length = target.len});
    }
  }

  template <Allocator Memory>
  void RowCache<Memory>::compactUris() {
    Vector<Byte, Memory> kept{uris_.get_allocator()};

    for (auto& link : links_) {
      const auto offset = kept.size();

      kept.insert(kept.end(), uris_.begin() + link.uri_offset, uris_.begin() + link.uri_offset + link.uri_length);
      link.uri_offset = static_cast<std::uint32_t>(offset);
    }

    uris_.swap(kept);
  }

  template class RowCache<Memory>;
  template class RowCache<ConcurrentMemory>;

}
