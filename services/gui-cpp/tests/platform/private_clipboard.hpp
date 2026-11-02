#pragma once

#include <cstddef>
#include <memory>
#include <span>

namespace telar::gui::test {

// Redirects only this test process's general-pasteboard lookup to a unique
// board. Neither the system clipboard nor another application is modified.
class PrivateClipboard {
public:
  PrivateClipboard();
  ~PrivateClipboard();
  PrivateClipboard(const PrivateClipboard &) = delete;
  PrivateClipboard &operator=(const PrivateClipboard &) = delete;
  PrivateClipboard(PrivateClipboard &&) = delete;
  PrivateClipboard &operator=(PrivateClipboard &&) = delete;

  void setPng(std::span<const std::byte> bytes);
  void clear();

private:
  struct Native;
  std::unique_ptr<Native> native_;
};

}
