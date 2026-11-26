export module telar.gui.platform:clipboard_image_transfer;

import std;

import :clipboard_image_pipe;
import telar.base.ds;

// The transfer status shared between the clipboard reader and pipe on Linux.
export namespace telar::gui::platform {

  class ClipboardImageTransfer {
  public:
    void fail(ClipboardImageError error) noexcept;
    [[nodiscard]] ds::Option<ClipboardImageError> failure() const noexcept;

  private:
    ClipboardImageError error_ = ClipboardImageError::read_failed;
    std::atomic<bool> failed_ = false;
  };

}
