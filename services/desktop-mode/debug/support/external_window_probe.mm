#include "external_window_probe.hpp"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <ApplicationServices/ApplicationServices.h>
#include <algorithm>
#include <dlfcn.h>
#include <vector>
#include <utility>

namespace {
  using WindowIdentifier = AXError (*)(AXUIElementRef, CGWindowID *);
  constexpr std::uint32_t display_limit = 16;
  constexpr int coverage_samples = 48;

  AXUIElementRef element(const void *value) {
    return static_cast<AXUIElementRef>(const_cast<void *>(value));
  }

  bool point(AXUIElementRef window, CFStringRef attribute, AXValueType type, void *out) {
    CFTypeRef value = nullptr;
    const bool valid =
        AXUIElementCopyAttributeValue(window, attribute, &value) == kAXErrorSuccess && value &&
        CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetValue(static_cast<AXValueRef>(value), type, out);
    if (value) {
      CFRelease(value);
    }

    return valid;
  }
} // namespace

namespace external_window_probe {
  bool trusted() {
    return AXIsProcessTrusted();
  }

  Window::Window(const void *value, std::uint32_t id)
      : element_(CFRetain(value)),
        id_(id) {}

  Window::~Window() {
    if (element_) {
      CFRelease(element_);
    }
  }

  Window::Window(Window &&other) noexcept
      : element_(std::exchange(other.element_, nullptr)),
        id_(other.id_) {}

  Window &Window::operator=(Window &&other) noexcept {
    if (this != &other) {
      if (element_) {
        CFRelease(element_);
      }

      element_ = std::exchange(other.element_, nullptr);
      id_ = other.id_;
    }

    return *this;
  }

  std::uint32_t Window::id() const {
    return id_;
  }

  QRectF Window::frame() const {
    CGPoint origin{};
    CGSize size{};
    if (!point(element(element_), kAXPositionAttribute, kAXValueTypeCGPoint, &origin) ||
        !point(element(element_), kAXSizeAttribute, kAXValueTypeCGSize, &size)) {
      return {};
    }

    return {origin.x, origin.y, size.width, size.height};
  }

  bool Window::setPosition(QPointF position) {
    CGPoint origin{position.x(), position.y()};
    const auto value = AXValueCreate(kAXValueTypeCGPoint, &origin);
    const auto result =
        AXUIElementSetAttributeValue(element(element_), kAXPositionAttribute, value);
    CFRelease(value);
    return result == kAXErrorSuccess;
  }

  bool Window::raise() {
    return AXUIElementPerformAction(element(element_), kAXRaiseAction) == kAXErrorSuccess;
  }

  bool Window::setMinimized(bool minimized) {
    return AXUIElementSetAttributeValue(element(element_),
                                        kAXMinimizedAttribute,
                                        minimized ? kCFBooleanTrue : kCFBooleanFalse) ==
           kAXErrorSuccess;
  }

  void Window::setTimeout(double seconds) {
    AXUIElementSetMessagingTimeout(element(element_), static_cast<float>(seconds));
  }

  std::int64_t processNamed(const QString &name) {
    NSString *wanted = name.toNSString();
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
      if ([application.localizedName isEqualToString:wanted] ||
          [application.bundleIdentifier isEqualToString:wanted]) {
        return application.processIdentifier;
      }
    }

    return 0;
  }

  std::vector<Window> windowsOf(std::int64_t pid) {
    const auto identifier =
        reinterpret_cast<WindowIdentifier>(dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"));
    std::vector<Window> result;
    if (!identifier) {
      return result;
    }

    AXUIElementRef application = AXUIElementCreateApplication(static_cast<pid_t>(pid));
    CFTypeRef windows = nullptr;
    if (AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windows) ==
            kAXErrorSuccess &&
        windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
      const auto list = static_cast<CFArrayRef>(windows);
      for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
        auto window =
            static_cast<AXUIElementRef>(const_cast<void *>(CFArrayGetValueAtIndex(list, index)));
        CGWindowID id = 0;
        CFTypeRef role = nullptr;
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute, &role);
        const bool standard = role && CFGetTypeID(role) == CFStringGetTypeID() &&
                              CFEqual(role, kAXStandardWindowSubrole);
        if (role) {
          CFRelease(role);
        }

        if (standard && identifier(window, &id) == kAXErrorSuccess && id) {
          result.emplace_back(window, id);
        }
      }
    }

    if (windows) {
      CFRelease(windows);
    }

    CFRelease(application);
    return result;
  }

  double visibleArea(std::uint32_t id) {
    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    std::vector<CGRect> above;
    CGRect bounds = CGRectNull;

    // Front to back: every window before this one may cover it.
    for (NSDictionary *window in windows) {
      CGRect frame{};
      if (!CGRectMakeWithDictionaryRepresentation(
              (__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds],
              &frame)) {
        continue;
      }

      if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == id) {
        bounds = frame;
        break;
      }

      if ([window[(__bridge NSString *)kCGWindowAlpha] doubleValue] > 0) {
        above.push_back(frame);
      }
    }

    if (CGRectIsNull(bounds)) {
      return 0;
    }

    double area = 0;
    std::uint32_t count = 0;
    CGDirectDisplayID displays[display_limit];
    CGGetActiveDisplayList(display_limit, displays, &count);
    for (std::uint32_t index = 0; index < count; ++index) {
      const auto overlap = CGRectIntersection(bounds, CGDisplayBounds(displays[index]));
      if (CGRectIsNull(overlap) || CGRectIsEmpty(overlap)) {
        continue;
      }

      // The uncovered share is sampled on a grid over the part on this display.
      int uncovered = 0;
      for (int row = 0; row < coverage_samples; ++row) {
        for (int column = 0; column < coverage_samples; ++column) {
          const CGPoint point{
              overlap.origin.x + overlap.size.width * (column + 0.5) / coverage_samples,
              overlap.origin.y + overlap.size.height * (row + 0.5) / coverage_samples};
          uncovered += std::ranges::none_of(above, [&](const CGRect &cover) {
            return CGRectContainsPoint(cover, point);
          });
        }
      }

      area += overlap.size.width * overlap.size.height * uncovered /
              (coverage_samples * coverage_samples);
    }

    return area;
  }

  int stackIndex(std::uint32_t id) {
    NSArray *windows = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    int index = 0;
    for (NSDictionary *window in windows) {
      if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == id) {
        return index;
      }

      ++index;
    }

    return -1;
  }

  Wall::Wall(QRectF frame) {
    // AppKit puts the origin at the bottom left of the main display.
    const auto top = NSMaxY(NSScreen.screens.firstObject.frame);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(frame.x(),
                                                                        top - frame.bottom(),
                                                                        frame.width(),
                                                                        frame.height())
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.level = NSNormalWindowLevel;
    window.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.09 blue:0.14 alpha:1];
    window.opaque = YES;
    window.hasShadow = NO;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    window_ = (void *)CFBridgingRetain(window);
  }

  Wall::~Wall() {
    NSWindow *window = CFBridgingRelease(window_);
    [window orderOut:nil];
    [window close];
  }

  void Wall::orderBelow(std::uint32_t window) {
    NSWindow *wall = (__bridge NSWindow *)window_;
    // Ordering relative to another window does not bring in a window that is not on screen.
    if (!wall.visible) {
      [wall orderFrontRegardless];
    }

    [wall orderWindow:NSWindowBelow relativeTo:window];
    // The bench never returns to the run loop, which is where AppKit would draw the wall and
    // commit it to the window server.
    [wall display];
    [CATransaction flush];
  }

  void Wall::orderOut() {
    [(__bridge NSWindow *)window_ orderOut:nil];
  }

  std::uint32_t Wall::id() const {
    return static_cast<std::uint32_t>(((__bridge NSWindow *)window_).windowNumber);
  }

  std::int64_t frontmost() {
    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  }

  void activate(std::int64_t pid, bool all_windows) {
    [[NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(pid)]
        activateWithOptions:all_windows ? NSApplicationActivateAllWindows : 0];
  }
} // namespace external_window_probe
