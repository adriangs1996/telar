#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct TerminalStorageSnapshot {
  std::uint64_t page_bytes = 0;
  std::uint64_t screen_bytes = 0;

  void merge(const TerminalStorageSnapshot &other) noexcept {
    accumulate(page_bytes, other.page_bytes);
    accumulate(screen_bytes, other.screen_bytes);
  }

  void write(Line &line) const {
    line.field("vt_scrollback_bytes", page_bytes);
    line.field("vt_screen_bytes", screen_bytes);
  }
};

}
