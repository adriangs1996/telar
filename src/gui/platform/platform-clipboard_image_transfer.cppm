export module telar.gui.platform:clipboard_image_transfer;

import std;

import :clipboard_image_pipe;
import telar.base.ds;

// This class completes the forward declaration in the Objective-C++ ABI.
export namespace telar::gui::platform {

  extern "C++" class ClipboardImageTransfer {
  public:
    inline void fail(ClipboardImageError error) noexcept {
      if (failed_.load(std::memory_order_relaxed)) {
        return;
      }

      error_ = error;
      failed_.store(true, std::memory_order_release);
    }

    [[nodiscard]] inline ds::Option<ClipboardImageError> failure() const noexcept {
      if (failed_.load(std::memory_order_acquire)) {
        return error_;
      }

      return ds::none;
    }

  private:
    ClipboardImageError error_ = ClipboardImageError::read_failed;
    std::atomic<bool> failed_ = false;
  };

}
