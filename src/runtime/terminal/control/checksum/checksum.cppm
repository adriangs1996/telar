export module telar.runtime.terminal.control.checksum;

import std;
import telar.base.memory.allocators;
import telar.ghostty.vt;
import telar.runtime.terminal.control;
import telar.runtime.terminal.grid;
import telar.base.ds;

export namespace telar::runtime::control {

  enum class ChecksumFlag : unsigned {
    positive = 1,
    no_attributes = 2,
    no_trim = 4,
    undrawn = 8,
    full = 16,
  };

  class Checksum {
  public:
    explicit Checksum(ConcurrentMemory& memory);

    void discard() noexcept;

    std::uint16_t compute(const VtState& state, const Parameters& request);

    unsigned flags = 0;

  private:
    template <bool NoAttributes>
    static consteval std::uint64_t plainCellMask() {
      std::uint64_t mask = 0;

      for (unsigned bit = 0; bit < std::numeric_limits<std::uint64_t>::digits; ++bit) {
        const auto cell = std::uint64_t{1} << bit;
        if (cell_layout::wide(cell) != 0 || (!NoAttributes && (cell_layout::style_id(cell) != 0 || cell_layout::protected_cell(cell) != 0))) {
          mask |= cell;
        }
      }

      return mask;
    }

    struct Rectangle {
      std::uint16_t top;
      std::uint16_t left;
      std::uint16_t bottom;
      std::uint16_t right;
    };

    // XTCHECKSUM has four traversal flags. Specialize their finite combinations
    // once per request, keeping invariant flag branches out of the cell loop.
    template <unsigned SelectedFlags>
    std::uint16_t accumulate(const VtState& state, Rectangle rectangle);

    using Accumulator = std::uint16_t (Checksum::*)(const VtState&, Rectangle);
    static const ds::Array<Accumulator, 16> accumulators;

    // Gather only selected grapheme columns. The state port normalizes a
    // bounded prefix; C++ owns the checksum arithmetic and guarantees progress.
    [[gnu::noinline]] std::uint16_t combiningBatch(GhosttyGridRef reference, std::span<const std::uint16_t> columns);

    std::uint16_t combining(const GhosttyGridRef& reference);

    static constexpr unsigned origin_mode = 6;
    static constexpr std::uint16_t escape_value = 0x1b;
    static constexpr std::size_t maximum_grapheme_points = std::numeric_limits<std::uint16_t>::max();
    static constexpr std::size_t maximum_batch_columns = 256;
    static constexpr std::size_t batch_points = 256;
    ds::Vec<std::uint32_t, ConcurrentMemory> graphemes_;
  };

}
