#include "../../ui/workbench/native.hpp"
#include "spaces_bridge.hpp"
#include "../../trace.hpp"
#include <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <QWindow>
#include <dlfcn.h>
#include <stdexcept>

namespace workbench::native {
  namespace {
    constexpr float accessibility_timeout = 0.15f;
    using WindowIdentifier = AXError (*)(AXUIElementRef, CGWindowID *);

    AXUIElementRef findWindow(std::uint32_t identifier) {
      if (!AXIsProcessTrusted()) {
        throw std::runtime_error("Accessibility permission is required to adopt external windows");
      }

      const auto get_id =
          reinterpret_cast<WindowIdentifier>(dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"));
      if (!get_id) {
        throw std::runtime_error("Native window identity API is unavailable");
      }

      NSArray *windows = CFBridgingRelease(
          CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
                                     kCGNullWindowID));
      for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] != identifier) {
          continue;
        }

        const auto pid = [window[(__bridge NSString *)kCGWindowOwnerPID] intValue];
        if (pid == getpid()) {
          throw std::runtime_error("A Telar window cannot be adopted as an external window");
        }

        AXUIElementRef application = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(application, accessibility_timeout);
        CFTypeRef value = nullptr;
        const auto result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &value);
        CFRelease(application);
        if (result != kAXErrorSuccess || !value) {
          continue;
        }

        AXUIElementRef found = nullptr;
        if (CFGetTypeID(value) == CFArrayGetTypeID()) {
          auto list = static_cast<CFArrayRef>(value);
          for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
            auto element = static_cast<AXUIElementRef>(
                const_cast<void *>(CFArrayGetValueAtIndex(list, index)));
            CGWindowID id = 0;
            if (get_id(element, &id) == kAXErrorSuccess && id == identifier) {
              found = static_cast<AXUIElementRef>(CFRetain(element));
              break;
            }
          }
        }

        CFRelease(value);
        if (found) {
          AXUIElementSetMessagingTimeout(found, accessibility_timeout);
          return found;
        }
      }

      throw std::runtime_error("External window no longer exists or cannot be controlled");
    }

    bool minimized(AXUIElementRef window) {
      CFTypeRef value = nullptr;
      const auto result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute, &value);
      const bool answer = result == kAXErrorSuccess && value &&
                          CFGetTypeID(value) == CFBooleanGetTypeID() &&
                          CFBooleanGetValue(static_cast<CFBooleanRef>(value));
      if (value) {
        CFRelease(value);
      }

      return answer;
    }
  } // namespace

  Display display(std::uint32_t identifier) {
    TELAR_TRACE("native.display");
    for (NSScreen *screen in NSScreen.screens) {
      if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] != identifier) {
        continue;
      }

      const auto top = NSMaxY(NSScreen.screens.firstObject.frame);
      const auto rect = screen.visibleFrame;
      return {{NSMinX(rect), top - NSMaxY(rect), NSWidth(rect), NSHeight(rect)},
              screen.backingScaleFactor};
    }

    return {};
  }

  void place(QWindow &window, std::uint64_t space) {
    TELAR_TRACE("native.place");
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    NSWindow *native = view.window;
    if (!native) {
      throw std::runtime_error("Qt did not create a native pane window");
    }

    native.collectionBehavior =
        NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorFullScreenAuxiliary;
    native.hidesOnDeactivate = NO;
    native.animationBehavior = NSWindowAnimationBehaviorNone;
    native.level = NSNormalWindowLevel;
    macos::spaces::moveWindow(static_cast<std::uint32_t>(native.windowNumber), space);
  }

  void prepareInputWindow(QWindow &window) {
    TELAR_TRACE("native.prepare_input_window");
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());
    NSWindow *native = view.window;
    if (!native) {
      throw std::runtime_error("Qt did not create the native keyboard window");
    }

    native.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    native.ignoresMouseEvents = YES;
    native.hidesOnDeactivate = NO;
    native.animationBehavior = NSWindowAnimationBehaviorNone;
  }

  void commitComposition(QWindow &window) {
    TELAR_TRACE("native.commit_composition");
    auto *view = (__bridge NSView<NSTextInputClient> *)reinterpret_cast<void *>(window.winId());
    if (![view hasMarkedText]) {
      return;
    }

    [view unmarkText];
    [view.inputContext discardMarkedText];
  }

  QVariantList windows() {
    TELAR_TRACE("native.windows");
    QVariantList result;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));
    for (NSDictionary *window in windows) {
      if ([window[(__bridge NSString *)kCGWindowLayer] intValue] != 0 ||
          [window[(__bridge NSString *)kCGWindowOwnerPID] intValue] == getpid()) {
        continue;
      }

      NSString *title = window[(__bridge NSString *)kCGWindowName];
      NSString *application = window[(__bridge NSString *)kCGWindowOwnerName];
      result.push_back(QVariantMap{
          {"id", QString::number([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue])},
          {"title", QString::fromUtf8(title.UTF8String ?: "")},
          {"application", QString::fromUtf8(application.UTF8String ?: "")}});
    }

    return result;
  }

  struct ExternalWindow::Impl {
    AXUIElementRef window = nullptr;
    AXObserverRef observer = nullptr;
    std::uint32_t identifier = 0;
    bool geometry_changed = true, destroyed = false;
    bool was_minimized = false;
    bool hidden = false;

    ~Impl() {
      if (observer) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              kCFRunLoopCommonModes);
        CFRelease(observer);
      }

      if (window) {
        if (hidden) {
          AXUIElementSetAttributeValue(window,
                                       kAXMinimizedAttribute,
                                       was_minimized ? kCFBooleanTrue : kCFBooleanFalse);
        }

        CFRelease(window);
      }
    }
  };

  ExternalWindow::ExternalWindow(std::uint32_t identifier)
      : impl_(std::make_unique<Impl>()) {
    impl_->window = findWindow(identifier);
    impl_->identifier = identifier;
    impl_->was_minimized = minimized(impl_->window);
    Boolean can_minimize = false;
    if (AXUIElementIsAttributeSettable(impl_->window, kAXMinimizedAttribute, &can_minimize) !=
            kAXErrorSuccess ||
        !can_minimize) {
      throw std::runtime_error(
          "External window cannot be hidden independently when switching tabs");
    }

    pid_t pid = 0;
    AXUIElementGetPid(impl_->window, &pid);
    if (AXObserverCreate(
            pid,
            [](AXObserverRef, AXUIElementRef, CFStringRef notification, void *context) {
              auto *impl = static_cast<Impl *>(context);
              if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
                impl->destroyed = true;
              } else {
                impl->geometry_changed = true;
              }
            },
            &impl_->observer) == kAXErrorSuccess) {
      for (const auto notification : {kAXWindowMovedNotification,
                                      kAXWindowResizedNotification,
                                      kAXUIElementDestroyedNotification}) {
        AXObserverAddNotification(impl_->observer, impl_->window, notification, impl_.get());
      }

      CFRunLoopAddSource(CFRunLoopGetMain(),
                         AXObserverGetRunLoopSource(impl_->observer),
                         kCFRunLoopCommonModes);
    }
  }

  ExternalWindow::~ExternalWindow() = default;

  bool ExternalWindow::alive() const {
    if (impl_->destroyed) {
      return false;
    }

    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, impl_->identifier));
    return windows.count != 0;
  }

  QRectF ExternalWindow::frame() const {
    CGPoint point{};
    CGSize size{};
    CFTypeRef position = nullptr, dimensions = nullptr;
    AXUIElementCopyAttributeValue(impl_->window, kAXPositionAttribute, &position);
    AXUIElementCopyAttributeValue(impl_->window, kAXSizeAttribute, &dimensions);
    const bool valid =
        position && dimensions && CFGetTypeID(position) == AXValueGetTypeID() &&
        CFGetTypeID(dimensions) == AXValueGetTypeID() &&
        AXValueGetValue(static_cast<AXValueRef>(position), kAXValueTypeCGPoint, &point) &&
        AXValueGetValue(static_cast<AXValueRef>(dimensions), kAXValueTypeCGSize, &size);
    if (position) {
      CFRelease(position);
    }

    if (dimensions) {
      CFRelease(dimensions);
    }

    if (!valid) {
      throw std::runtime_error("Unable to read external window geometry");
    }

    impl_->geometry_changed = false;
    return {point.x, point.y, size.width, size.height};
  }

  QRectF ExternalWindow::place(const QRectF &requested) {
    TELAR_TRACE("native.external.place");
    CGPoint point{requested.x(), requested.y()};
    CGSize size{requested.width(), requested.height()};
    const auto position = AXValueCreate(kAXValueTypeCGPoint, &point);
    const auto dimensions = AXValueCreate(kAXValueTypeCGSize, &size);
    AXUIElementSetAttributeValue(impl_->window, kAXSizeAttribute, dimensions);
    AXUIElementSetAttributeValue(impl_->window, kAXPositionAttribute, position);
    CFRelease(position);
    CFRelease(dimensions);
    return frame();
  }

  void ExternalWindow::show(bool visible) {
    TELAR_TRACE("native.external.show");
    if (impl_->hidden == !visible) {
      return;
    }

    const auto result = AXUIElementSetAttributeValue(impl_->window,
                                                     kAXMinimizedAttribute,
                                                     visible ? kCFBooleanFalse : kCFBooleanTrue);
    if (result != kAXErrorSuccess) {
      throw std::runtime_error("External application refused tab visibility change");
    }

    impl_->hidden = !visible;
  }

  void ExternalWindow::focus() {
    TELAR_TRACE("native.external.focus");
    show(true);
    pid_t pid = 0;
    AXUIElementGetPid(impl_->window, &pid);
    [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:0];
    AXUIElementPerformAction(impl_->window, kAXRaiseAction);
    AXUIElementSetAttributeValue(impl_->window, kAXMainAttribute, kCFBooleanTrue);
  }

  QString ExternalWindow::title() const {
    CFTypeRef title = nullptr;
    AXUIElementCopyAttributeValue(impl_->window, kAXTitleAttribute, &title);
    QString result;
    if (title && CFGetTypeID(title) == CFStringGetTypeID()) {
      result = QString::fromUtf8([(__bridge NSString *)title UTF8String]);
    }

    if (title) {
      CFRelease(title);
    }

    return result;
  }

  void ExternalWindow::setSpace(std::uint64_t space) {
    TELAR_TRACE("native.external.set_space");
    macos::spaces::moveWindow(impl_->identifier, space);
  }

  bool ExternalWindow::geometryChanged() const {
    return impl_->geometry_changed;
  }

  bool ExternalWindow::focused() const {
    pid_t pid = 0;
    AXUIElementGetPid(impl_->window, &pid);
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != pid) {
      return false;
    }

    CFTypeRef value = nullptr;
    const auto result = AXUIElementCopyAttributeValue(impl_->window, kAXMainAttribute, &value);
    const bool focused = result == kAXErrorSuccess && value &&
                         CFGetTypeID(value) == CFBooleanGetTypeID() &&
                         CFBooleanGetValue(static_cast<CFBooleanRef>(value));
    if (value) {
      CFRelease(value);
    }
    return focused;
  }
} // namespace workbench::native
