module telar.gui.foundation.core;

import std;

namespace telar::gui::inline foundation::inline core {

  void eraseSensitiveBytes(std::span<std::byte> bytes) noexcept {
    // Each write is volatile, so the compiler keeps the ones that nothing reads afterwards.
    for (std::size_t index = 0; index < bytes.size(); ++index) { // NOLINT(modernize-loop-convert): misc-const-correctness sees no write through a range-for's element under the volatile cast
      static_cast<volatile std::byte&>(bytes[index]) = std::byte{};
    }
  }

  void AttachmentTarget::validate() const {
    if (pane_id == invalid_pane || pane_generation == invalid_generation) {
      throw std::invalid_argument{"InvalidAttachmentTarget"};
    }
  }

}
