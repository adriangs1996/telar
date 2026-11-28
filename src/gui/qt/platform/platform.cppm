module;
#include "platform/clipboard_image_monitor.hpp"
#include "platform/file_drag.hpp"
#include "platform/scroll_event.hpp"
#include "platform/text_input.hpp"
#include "platform/window.hpp"

export module telar.gui.qt.platform;

export namespace telar::gui::platform {
  using ::telar::gui::platform::ClipboardImageMonitor;
  using ::telar::gui::platform::configureGraphics;
  using ::telar::gui::platform::configureKeyRepeat;
  using ::telar::gui::platform::configureWindow;
  using ::telar::gui::platform::defaultTitlebar;
  using ::telar::gui::platform::deliverPendingWindowUpdate;
  using ::telar::gui::platform::DraggedOut;
  using ::telar::gui::platform::file_promises;
  using ::telar::gui::platform::FileDrag;
  using ::telar::gui::platform::isCompositionCancellation;
  using ::telar::gui::platform::layoutTakesOptionForAlt;
  using ::telar::gui::platform::native_composition_events;
  using ::telar::gui::platform::native_scroll_events;
  using ::telar::gui::platform::NativeScrollInput;
  using ::telar::gui::platform::nativeScrollInput;
  using ::telar::gui::platform::PromiseAsked;
  using ::telar::gui::platform::PromisedFile;
  using ::telar::gui::platform::supportsImmediateWindowUpdates;
  using ::telar::gui::platform::usesCommandKey;
  using ::telar::gui::platform::WindowAppearance;
  using ::telar::gui::platform::windowControls;
}
