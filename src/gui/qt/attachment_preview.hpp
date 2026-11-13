#pragma once

#include "application/dependencies.hpp"
#include "attachments/catalog.hpp"
#include <QImage>
#include <cstdint>

namespace telar::gui::qt {

struct AttachmentPreview {
  std::uint64_t sequence = 0;
  QImage thumbnail;
  QImage full;

  [[nodiscard]] static AttachmentPreview decode(ApplicationAllocator &memory, const AttachmentCapture<ApplicationAllocator> &capture);
};

}
