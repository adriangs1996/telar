// A clipboard image on its way into the shelf, the keys that delete an image's marker from the
// prompt, and the size an image's preview is drawn at.
export module telar.gui.features.terminal.attachments:capture;

import std;

import :catalog;
import telar.gui.foundation.actions;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: attachments/capture_state.cppm
export {
  namespace telar::gui::features::terminal::attachments {

    class ClipboardCaptureState {
    public:
      explicit ClipboardCaptureState(std::uint64_t next_id = ClipboardCapture::first_id) noexcept;

      [[nodiscard]] const ds::Option<ClipboardCapture>& current() const noexcept;

      [[nodiscard]] std::uint64_t nextId() const noexcept;

      [[nodiscard]] ds::Option<ClipboardCapture> reserve(AttachmentTarget target);

      [[nodiscard]] ds::Option<ClipboardCapture> finish(std::uint64_t id) noexcept;

      bool cancel(AttachmentTarget target) noexcept;

    private:
      std::uint64_t next_id_;
      ds::Option<ClipboardCapture> capture_;
    };

  }
}

// Interface: attachments/marker_input.cppm
export {
  namespace telar::gui::features::terminal::attachments {

    class AttachmentMarkerInput {
    public:
      explicit AttachmentMarkerInput(AttachmentMarkerRemoval removal, const InputModes& modes);

      [[nodiscard]] std::string_view view() const noexcept;

    private:
      void append(KeyChord::Key code, std::uint16_t count, const InputModes& modes);

      ds::Array<char, AttachmentLimits::maximum_input_bytes> bytes_{};
      std::size_t used_ = 0;
    };

  }
}

// Interface: attachments/preview_size.cppm
export {
  namespace telar::gui::features::terminal::attachments {

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
