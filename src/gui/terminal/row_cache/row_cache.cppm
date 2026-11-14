module;
#include "tbc/annotations.hpp"

export module telar.gui.terminal.row_cache;

import std;
import telar.base.memory.allocators;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;
import telar.wire.content;
import telar.wire.vocabulary;

export namespace telar::gui {

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

    explicit RowCache(Memory& memory);

    // The rows' numbering: rows of another generation are forgotten, as are requests for them.
    void number(std::uint64_t generation);

    [[nodiscard]] std::uint64_t generation() const noexcept;

    // Keeps the rows of `reply`, when they are numbered as the cache numbers rows and as wide
    // as `columns`. Whether any were kept.
    bool store(const PaneRows& reply, std::uint16_t columns);

    // A hyperlink on a held row as `links` shows it.
    struct LinkView {
      std::uint16_t column = 0;
      std::uint32_t length = 0;
      std::string_view uri;
    };

    // Calls `visit` with each hyperlink on held row `stable`. Generic over the caller's visitor,
    // so it stays here.
    template <typename Visitor>
    TBC_HOT_PATH void links(std::uint64_t stable, Visitor&& visit) const {
      if (!holds(stable)) {
        return;
      }

      for (const auto& link : links_) {
        if (link.stable == stable) {
          visit(LinkView{.column = link.column, .length = link.length, .uri = textView(std::span{uris_}.subspan(link.uri_offset, link.uri_length))});
        }
      }
    }

    [[nodiscard]] std::optional<Row> find(std::uint64_t stable) const noexcept;

    [[nodiscard]] bool holds(std::uint64_t stable) const noexcept;

    // The first of the rows from `first` to `last` neither held nor asked for, if any: the next
    // request starts there.
    [[nodiscard]] std::optional<std::uint64_t> missing(std::uint64_t first, std::uint64_t last) const noexcept;

    [[nodiscard]] bool full() const noexcept;

    // A request for the rows from `from`, in flight until its reply or its failure settles it.
    void ask(std::uint64_t request_id, std::uint64_t from, std::uint16_t count) noexcept;

    // Whether `request_id` is one of the cache's, which it no longer waits for.
    bool settle(std::uint64_t request_id) noexcept;

    // Forgets every row and request, and gives the slots back.
    void release();

    [[nodiscard]] bool empty() const noexcept;

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

    [[nodiscard]] bool asked(std::uint64_t stable) const noexcept;

    void forget() noexcept;

    void dropLinks(std::uint64_t stable) noexcept;

    // The reply's hyperlinks by the row they are on, with copies of their targets.
    void keepLinks(const PaneRows& reply, const TextMetadata& metadata);

    // Keeps only the targets of links still held.
    void compactUris();

    Vector<CellValue, Memory> cells_;
    Vector<Slot, Memory> slots_;
    Vector<Link, Memory> links_;
    Vector<Byte, Memory> uris_;
    std::array<Pending, maximum_pending> pending_{};
    std::uint64_t generation_ = 0;
    std::uint64_t revision_ = 0;
    std::uint16_t columns_ = 0;
  };

  extern template class RowCache<Memory>;
  extern template class RowCache<ConcurrentMemory>;

}
