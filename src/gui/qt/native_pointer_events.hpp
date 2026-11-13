#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"

namespace telar::gui::qt {

class NativePointerEvents {
public:
  explicit NativePointerEvents(ApplicationAllocator &memory);
  ~NativePointerEvents();
  NativePointerEvents(const NativePointerEvents &) = delete;
  NativePointerEvents &operator=(const NativePointerEvents &) = delete;
  NativePointerEvents(NativePointerEvents &&) = delete;
  NativePointerEvents &operator=(NativePointerEvents &&) = delete;

  [[nodiscard]] bool moving() const noexcept;

private:
  struct Native;
  Owned<Native, ApplicationAllocator> native_;
};

}
