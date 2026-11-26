#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QImage>
#include <cstdint>

#pragma once

import telar.gui.foundation.core;

namespace telar::gui::qt {

  struct AttachmentPreview {
    std::uint64_t sequence = 0;
    QImage thumbnail;
    QImage full;

    [[nodiscard]] static AttachmentPreview decode(ApplicationAllocator& memory, const AttachmentCapture<ApplicationAllocator>& capture);
  };

}
