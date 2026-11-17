#pragma once

#include "features/terminal/attachments/capture.hpp"
#include "foundation/core/application_memory.hpp"
#include <QImage>
#include <cstdint>

namespace telar::gui::qt {

  struct AttachmentPreview {
    std::uint64_t sequence = 0;
    QImage thumbnail;
    QImage full;

    [[nodiscard]] static AttachmentPreview decode(ApplicationAllocator& memory, const AttachmentCapture<ApplicationAllocator>& capture);
  };

}
