export module telar.gui.attachments.marker_input;

import std;

export import telar.gui.input.key_encoder;
import telar.gui.attachments.catalog;
import telar.wire.vocabulary;

// Interface: attachments/capture_state.cppm
export {
  namespace telar::gui {

    class ClipboardCaptureState {
    public:
      explicit ClipboardCaptureState(std::uint64_t next_id = ClipboardCapture::first_id) noexcept;

      [[nodiscard]] const std::optional<ClipboardCapture>& current() const noexcept;

      [[nodiscard]] std::uint64_t nextId() const noexcept;

      [[nodiscard]] std::optional<ClipboardCapture> reserve(AttachmentTarget target);

      [[nodiscard]] std::optional<ClipboardCapture> finish(std::uint64_t id) noexcept;

      bool cancel(AttachmentTarget target) noexcept;

    private:
      std::uint64_t next_id_;
      std::optional<ClipboardCapture> capture_;
    };

  }
}

// Interface: attachments/marker_input.cppm
export {
  namespace telar::gui {

    class AttachmentMarkerInput {
    public:
      explicit AttachmentMarkerInput(AttachmentMarkerRemoval removal, const InputModes& modes);

      [[nodiscard]] std::string_view view() const noexcept;

    private:
      void append(KeyChord::Key code, std::uint16_t count, const InputModes& modes);

      std::array<char, AttachmentLimits::maximum_input_bytes> bytes_{};
      std::size_t used_ = 0;
    };

  }
}

// Interface: attachments/preview_size.cppm
export {
  namespace telar::gui {

    struct AttachmentPreviewBounds {
      std::uint32_t side;
      std::uint32_t pixels;
    };

    struct AttachmentPreviewSize {
      static constexpr std::uint32_t thumbnail_side = 256;
      static constexpr std::uint32_t full_side = 2048;
      static constexpr std::uint32_t full_pixels = std::uint32_t{2} * 1024 * 1024;

      std::uint32_t width = 0;
      std::uint32_t height = 0;

      [[nodiscard]] static AttachmentPreviewSize fit(std::uint32_t width, std::uint32_t height, AttachmentPreviewBounds bounds);
    };

  }
}
