module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.ghostty;

import std;
import telar.ghostty.vt;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::runtime {

  // Generic over the libghostty struct its caller sizes, so it stays here.
  template <typename Value>
  TBC_GENERIC Value ghosttySized() noexcept {
    Value value{};

    value.size = sizeof(Value);
    return value;
  }

  class TerminalError final : public std::exception {
  public:
    explicit TerminalError(GhosttyResult result, std::source_location location = std::source_location::current()) noexcept;

    [[nodiscard]] const char* what() const noexcept override;

    [[nodiscard]] constexpr GhosttyResult result() const noexcept {
      return result_;
    }

    [[nodiscard]] constexpr std::source_location location() const noexcept {
      return location_;
    }

  private:
    GhosttyResult result_;
    std::source_location location_;
  };

  void checkGhostty(GhosttyResult result, std::source_location location = std::source_location::current());

  // Owns a libghostty object. Its handle is a raw FFI pointer, unchecked as Rust's are: the objects that
  // keep it are destroyed before the owner releases it. Generic over the handle and the release its
  // caller names, so it stays here.
  template <typename Handle, auto Release>
  class TBC_SHARED TBC_GENERIC GhosttyHandle {
  public:
    GhosttyHandle() = default;

    ~GhosttyHandle() {
      if (handle_ != nullptr) {
        Release(handle_);
      }
    }

    GhosttyHandle(const GhosttyHandle&) = delete;
    GhosttyHandle& operator=(const GhosttyHandle&) = delete;
    GhosttyHandle(GhosttyHandle&&) = delete;
    GhosttyHandle& operator=(GhosttyHandle&&) = delete;

    Handle get() const noexcept {
      return handle_;
    }

    Handle* output() noexcept {
      return &handle_;
    }

  private:
    Handle handle_ = nullptr;
  };

  using TerminalHandle = GhosttyHandle<GhosttyTerminal, ghostty_terminal_free>;
  using RenderStateHandle = GhosttyHandle<GhosttyRenderState, ghostty_render_state_free>;
  using RowIteratorHandle = GhosttyHandle<GhosttyRenderStateRowIterator, ghostty_render_state_row_iterator_free>;
  using RowCellsHandle = GhosttyHandle<GhosttyRenderStateRowCells, ghostty_render_state_row_cells_free>;
  using FormatterHandle = GhosttyHandle<GhosttyFormatter, ghostty_formatter_free>;

  // Lends Ghostty the allocator, region `a`, which outlives the bridge. Generic over the caller's
  // allocator, so it stays here.
  template <Allocator Memory>
  class TBC_GENERIC GhosttyAllocatorBridge {
  public:
    explicit GhosttyAllocatorBridge(tbc::mut_a<Memory> memory) noexcept
        : allocator_{.ctx = &memory, .vtable = &callbacks} {}

    [[nodiscard]] const GhosttyAllocator* get() const noexcept {
      return &allocator_;
    }

    tbc::mut_a<Memory> memory() const noexcept {
      return *static_cast<Memory*>(allocator_.ctx);
    }

  private:
    static void* allocate(void* context, std::size_t size, std::uint8_t alignment, std::uintptr_t /*return_address*/) noexcept {
      TELAR_DIAGNOSTIC(TerminalAllocationScope allocation_scope);
      // The pinned ABI passes log2(alignment), despite allocator.h describing bytes.
      if (alignment >= std::numeric_limits<std::size_t>::digits) {
        return nullptr;
      }

      return static_cast<Memory*>(context)->allocate(size, std::size_t{1} << alignment);
    }

    static bool resize(void* /*context*/, void* /*memory*/, std::size_t /*size*/, std::uint8_t /*alignment*/, std::size_t /*new_size*/, std::uintptr_t /*return_address*/) noexcept { // NOLINT(readability-function-size): GhosttyAllocatorVtable's C signature takes six parameters
      return false;
    }

    static void* remap(void* /*context*/, void* /*memory*/, std::size_t /*size*/, std::uint8_t /*alignment*/, std::size_t /*new_size*/, std::uintptr_t /*return_address*/) noexcept { // NOLINT(readability-function-size): GhosttyAllocatorVtable's C signature takes six parameters
      return nullptr;
    }

    static void deallocate(void* context, void* pointer, std::size_t size, std::uint8_t alignment, std::uintptr_t /*return_address*/) noexcept {
      static_cast<Memory*>(context)->deallocate(pointer, size, std::size_t{1} << alignment);
    }

    inline static constexpr GhosttyAllocatorVtable callbacks{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = deallocate,
    };

    tbc::val_a<GhosttyAllocator> allocator_;
  };

  // A row of a terminal's grid that the terminal follows through reflow until the scrollback
  // drops it. Empty when ghostty could not track the row.
  class TrackedRow {
  public:
    TrackedRow() = default;

    // Follows the active area's row `row`.
    static TrackedRow active(GhosttyTerminal terminal, std::uint32_t row) noexcept;

    TrackedRow(const TrackedRow&) = delete;
    TrackedRow& operator=(const TrackedRow&) = delete;

    TrackedRow(TrackedRow&& other) noexcept;

    TrackedRow& operator=(TrackedRow&& other) noexcept;

    ~TrackedRow();

    constexpr explicit operator bool() const noexcept {
      return ref_ != nullptr;
    }

    // The row from the top of the scrollback; nothing once the scrollback dropped it.
    [[nodiscard]] ds::Option<std::uint32_t> row(GhosttyTerminal terminal) const noexcept;

  private:
    void release() noexcept;

    GhosttyTrackedGridRef ref_ = nullptr;
  };

}
