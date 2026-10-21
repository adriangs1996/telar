#include "../shortcuts.hpp"
#include "../../shortcuts.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <QDebug>
#include <QTimer>

namespace {
  NSString *specialKey(unsigned short code) {
    switch (code) {
    case kVK_Return:
    case kVK_ANSI_KeypadEnter:
      return @"enter";
    case kVK_Tab:
      return @"tab";
    case kVK_Delete:
      return @"backspace";
    case kVK_Escape:
      return @"escape";
    case kVK_ForwardDelete:
      return @"delete";
    case kVK_Home:
      return @"home";
    case kVK_End:
      return @"end";
    case kVK_PageUp:
      return @"pageup";
    case kVK_PageDown:
      return @"pagedown";
    case kVK_LeftArrow:
      return @"left";
    case kVK_RightArrow:
      return @"right";
    case kVK_UpArrow:
      return @"up";
    case kVK_DownArrow:
      return @"down";
    default:
      return nil;
    }
  }

  NSString *chord(NSEvent *event) {
    const auto flags = event.modifierFlags;
    const bool control = flags & NSEventModifierFlagControl;
    const bool command = flags & NSEventModifierFlagCommand;
    NSString *key = specialKey(event.keyCode);
    const bool special = key != nil;

    if (!key) {
      // Preserve the layout's printable result, matching lib/window's decoder.
      key = event.charactersIgnoringModifiers;

      if (control || command) {
        key = key.lowercaseString;
      }

      if ([key isEqualToString:@"+"]) {
        key = @"plus";
      }
    }

    if (!key.length) {
      return @"";
    }

    NSMutableString *result = [NSMutableString string];

    if (control) {
      [result appendString:@"ctrl+"];
    }
    if (command) {
      [result appendString:@"cmd+"];
    }
    if (flags & NSEventModifierFlagOption) {
      [result appendString:@"alt+"];
    }
    if ((flags & NSEventModifierFlagShift) && (special || control || command)) {
      [result appendString:@"shift+"];
    }

    [result appendString:key];
    return result;
  }
} // namespace

struct NativeShortcuts::Impl {
  Shortcuts &shortcuts;
  CFMachPortRef tap = nullptr;
  CFRunLoopSourceRef source = nullptr;
  QTimer retry;
  id activation_observer = nil;
  id sleep_observer = nil;

  explicit Impl(Shortcuts &shortcuts)
      : shortcuts(shortcuts) {
    auto *notifications = NSWorkspace.sharedWorkspace.notificationCenter;
    activation_observer =
        [notifications addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                   object:nil
                                    queue:NSOperationQueue.mainQueue
                               usingBlock:^(NSNotification *) {
                                 this->shortcuts.cancel();
                               }];
    sleep_observer = [notifications addObserverForName:NSWorkspaceSessionDidResignActiveNotification
                                                object:nil
                                                 queue:NSOperationQueue.mainQueue
                                            usingBlock:^(NSNotification *) {
                                              this->shortcuts.cancel();
                                            }];
    retry.setInterval(2000);
    QObject::connect(&retry, &QTimer::timeout, &retry, [this] {
      attach();
    });
    retry.start();
    attach();
  }

  ~Impl() {
    retry.stop();
    auto *notifications = NSWorkspace.sharedWorkspace.notificationCenter;
    [notifications removeObserver:activation_observer];
    [notifications removeObserver:sleep_observer];
    detach();
    shortcuts.status = {};
  }

  void detach() {
    if (source) {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
      CFRelease(source);
      source = nullptr;
    }
    if (tap) {
      CFMachPortInvalidate(tap);
      CFRelease(tap);
      tap = nullptr;
    }

    shortcuts.cancel();
  }

  void attach() {
    if (!tap && shortcuts.empty()) {
      return;
    }

    if (!AXIsProcessTrusted()) {
      if (tap) {
        detach();
      }
      const std::string message = "Desktop shortcuts need Accessibility permission for Telar "
                                  "Desktop (or the terminal launching it)";

      if (shortcuts.status.error != message) {
        qWarning().noquote() << QString::fromStdString(message);
      }

      shortcuts.status = {false, message};
      return;
    }

    if (tap) {
      return;
    }

    constexpr auto mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                          CGEventMaskBit(kCGEventLeftMouseDown) |
                          CGEventMaskBit(kCGEventRightMouseDown) |
                          CGEventMaskBit(kCGEventOtherMouseDown);
    tap = CGEventTapCreate(kCGSessionEventTap,
                           kCGHeadInsertEventTap,
                           kCGEventTapOptionDefault,
                           mask,
                           receive,
                           this);

    if (!tap) {
      shortcuts.status = {false, "macOS could not install the desktop shortcut event tap"};
      return;
    }

    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);

    if (!source) {
      CFMachPortInvalidate(tap);
      CFRelease(tap);
      tap = nullptr;
      shortcuts.status = {false, "Could not create the desktop shortcut run loop source"};
      return;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    shortcuts.status = {true, {}};
  }

  static CGEventRef receive(CGEventTapProxy, CGEventType type, CGEventRef event, void *info) {
    auto &self = *static_cast<Impl *>(info);

    @autoreleasepool {
      if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        self.shortcuts.cancel();
        CGEventTapEnable(self.tap, true);
        self.shortcuts.status.available = CGEventTapIsEnabled(self.tap);
        return event;
      }

      if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        self.shortcuts.cancel();
        return event;
      }

      const auto phase = type == kCGEventKeyUp ? keybindings::KeyPhase::Release
                         : CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)
                             ? keybindings::KeyPhase::Repeat
                             : keybindings::KeyPhase::Press;

      const auto physical =
          static_cast<std::uint32_t>(CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode));
      constexpr auto modifiers =
          kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
      const bool translate = phase == keybindings::KeyPhase::Press &&
                             (self.shortcuts.pending() || (CGEventGetFlags(event) & modifiers));
      const keybindings::KeyEvent key{translate ? chord([NSEvent eventWithCGEvent:event]).UTF8String
                                                : "",
                                      physical,
                                      phase};
      return self.shortcuts.route(key) ? nullptr : event;
    }
  }
};

NativeShortcuts::NativeShortcuts(Shortcuts &shortcuts)
    : impl_(std::make_unique<Impl>(shortcuts)) {}

NativeShortcuts::~NativeShortcuts() = default;
