export module telar.gui.ui.kit.input:native_pointer_events;

import telar.gui.foundation.core;
import telar.base.ds;

export namespace telar::gui::qt {

  class NativePointerEvents {
  public:
    explicit NativePointerEvents(ApplicationAllocator& memory);
    ~NativePointerEvents();
    NativePointerEvents(const NativePointerEvents&) = delete;
    NativePointerEvents& operator=(const NativePointerEvents&) = delete;
    NativePointerEvents(NativePointerEvents&&) = delete;
    NativePointerEvents& operator=(NativePointerEvents&&) = delete;

    [[nodiscard]] bool moving() const noexcept;

  private:
    struct Native;
    ds::Box<Native, ApplicationAllocator> native_;
  };

}
