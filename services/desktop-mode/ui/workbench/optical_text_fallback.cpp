#include "optical_text.hpp"
#include <QtGlobal>
#if !defined(Q_OS_MACOS)

namespace workbench {
  std::unique_ptr<OpticalText> OpticalText::create() {
    return nullptr;
  }
} // namespace workbench
#endif
