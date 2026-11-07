#pragma once

#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "core/memory.hpp"
#include <cstdint>

namespace telar::gui {

// Kept apart from the catalog so the Objective-C++ clipboard source shares only
// the capture it produces, not the catalog's terminal and protocol closure.
template <Allocator Memory>
struct AttachmentCapture {
  ClipboardCaptureRequest request;
  SensitiveBytes<Memory> png;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
};

}
