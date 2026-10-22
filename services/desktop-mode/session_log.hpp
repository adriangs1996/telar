#pragma once

// In builds with TELAR_DEBUG, every desktop session writes its own log file under the desktop
// state directory, with every Qt message of every category. In release builds open and close
// do nothing.
//
// The file must stay safe to share: never log terminal input, screen contents or clipboard data.
#include <cstddef>

namespace session_log {
  void open();
  void close();
  // This process's resident memory in bytes, or 0 where it cannot be read.
  std::size_t residentBytes();
} // namespace session_log
