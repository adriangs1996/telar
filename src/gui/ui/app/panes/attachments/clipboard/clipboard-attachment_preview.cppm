export module telar.gui.ui.app.panes.attachments.clipboard:attachment_preview;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  struct AttachmentPreview {
    std::uint64_t sequence = 0;
    QImage thumbnail;
    QImage full;

    [[nodiscard]] static AttachmentPreview decode(ApplicationAllocator& memory, const AttachmentCapture<ApplicationAllocator>& capture);
  };

}
