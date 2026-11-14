export module telar.gui.platform.clipboard_image_transfer;

import std;

import telar.gui.platform.clipboard_image_pipe;

// This class completes the forward declaration in the Objective-C++ ABI.
export extern "C++" {
  namespace telar::gui::platform {

    class ClipboardImageTransfer {
    public:
      inline void fail(ClipboardImageError error) noexcept {
        if (failed_.load(std::memory_order_relaxed)) {
          return;
        }

        error_ = error;
        failed_.store(true, std::memory_order_release);
      }

      [[nodiscard]] inline std::optional<ClipboardImageError> failure() const noexcept {
        if (failed_.load(std::memory_order_acquire)) {
          return error_;
        }

        return std::nullopt;
      }

    private:
      ClipboardImageError error_ = ClipboardImageError::read_failed;
      std::atomic<bool> failed_ = false;
    };

  }
}
