#pragma once

#include "tbc/view.hpp"
#include <exception>
#include <ghostty/vt.h>
#include <source_location>
#include <utility>

namespace telar::runtime {

template <typename Value>
Value ghosttySized() noexcept {
  Value value{};
  value.size = sizeof(Value);
  return value;
}

class TerminalError final : public std::exception {
public:
  explicit TerminalError(GhosttyResult result, std::source_location location = std::source_location::current()) noexcept
      : result_(result),
        location_(location) {}

  const char *what() const noexcept override {
    return "libghostty-vt operation failed";
  }

  GhosttyResult result() const noexcept {
    return result_;
  }

  std::source_location location() const noexcept {
    return location_;
  }

private:
  GhosttyResult result_;
  std::source_location location_;
};

inline void checkGhostty(GhosttyResult result, std::source_location location = std::source_location::current()) {
  if (result != GHOSTTY_SUCCESS) {
    throw TerminalError{result, location};
  }
}

// Owns a libghostty object. Its handle is a raw FFI pointer, unchecked as Rust's are: the objects that
// keep it are destroyed before the owner releases it.
template <typename Handle, auto Release>
class TBC_SHARED GhosttyHandle {
public:
  GhosttyHandle() = default;

  ~GhosttyHandle() {
    if (handle_ != nullptr) {
      Release(handle_);
    }
  }

  GhosttyHandle(const GhosttyHandle &) = delete;
  GhosttyHandle &operator=(const GhosttyHandle &) = delete;

  Handle get() const noexcept {
    return handle_;
  }

  Handle *output() noexcept {
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

}
