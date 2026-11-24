#include "platform/text_input.hpp"
#include "cf_reference.hpp"
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <QWindow>
#include <bit>
#include <string_view>

namespace telar::gui::platform {

  bool isCompositionCancellation(std::string_view event_type, const void* message, const QWindow& window) noexcept {
    if (event_type != "mac_generic_NSEvent" || message == nullptr || window.handle() == nullptr) {
      return false;
    }

    const auto* const event = (__bridge NSEvent*)message;
    constexpr auto shortcut_modifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    if (event.type != NSEventTypeKeyDown || event.keyCode != kVK_Escape || (event.modifierFlags & shortcut_modifiers) != 0) {
      return false;
    }

    const auto* handle = std::bit_cast<const void*>(window.winId());
    const auto* const view = (__bridge NSView*)handle;

    return event.window == view.window;
  }

  bool layoutTakesOptionForAlt() noexcept {
    const NativeReference<TISInputSourceRef> source{TISCopyCurrentKeyboardLayoutInputSource()};
    if (!source) {
      return false;
    }

    const auto* const identifier = static_cast<CFStringRef>(TISGetInputSourceProperty(source.get(), kTISPropertyInputSourceID));

    // ABC is U.S. under the name macOS gives it outside the U.S., with the same Option layer.
    return identifier != nullptr && (CFEqual(identifier, CFSTR("com.apple.keylayout.US")) != 0U || CFEqual(identifier, CFSTR("com.apple.keylayout.ABC")) != 0U || CFEqual(identifier, CFSTR("com.apple.keylayout.USInternational")) != 0U);
  }

}
