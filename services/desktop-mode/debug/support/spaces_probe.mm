#include "spaces_probe.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#include <atomic>
#include <dlfcn.h>
#include <stdexcept>

// Read-only operation signatures inspected in SkyLight on macOS 26.6.2.
@interface NSObject (TelarDebugSpacesBridge)
- (instancetype)initWithOptions:(unsigned)options windows:(NSArray *)windows;
- (NSArray *)propertyListArray;
- (NSArray *)numbers;
@end

namespace {
  constexpr std::uint32_t mission_control_enter = 1204;
  constexpr unsigned all_window_spaces = 7;

  void require(bool condition, const char *message) {
    if (!condition) {
      throw std::runtime_error(message);
    }
  }

  struct Bridge {
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_NOW | RTLD_LOCAL);
    using Notification = void (*)(std::uint32_t, void *, std::size_t, void *, int);
    int (*connection)() = load<decltype(connection)>("SLSMainConnectionID");
    CGError (*observe)(int,
                       Notification,
                       std::uint32_t,
                       void *) = load<decltype(observe)>("SLSRegisterConnectionNotifyProc");
    CGError (*unobserve)(int,
                         Notification,
                         std::uint32_t,
                         void *) = load<decltype(unobserve)>("SLSRemoveConnectionNotifyProc");

    template <typename Function> Function load(const char *name) {
      return library ? reinterpret_cast<Function>(dlsym(library, name)) : nullptr;
    }

    Bridge() {
      require(library && connection && observe && unobserve,
              "This macOS version does not expose the debug Spaces bridge");
    }

    // Keep the framework loaded for the process lifetime: its Objective-C classes remain registered.
    static Bridge &shared() {
      static Bridge bridge;
      return bridge;
    }
  };

  Class operationClass(NSString *name, SEL initializer) {
    Bridge::shared();
    const auto type = NSClassFromString(name);
    require(type && [type instancesRespondToSelector:initializer] &&
                [type instancesRespondToSelector:sel_registerName("performWithWMBridgeDelegate")],
            "A required SkyLight bridge operation is unavailable");
    return type;
  }

  id performSync(id operation) {
    require(operation != nil, "SkyLight did not initialize a synchronous operation");
    return reinterpret_cast<id (*)(id, SEL)>(
        objc_msgSend)(operation, sel_registerName("performWithWMBridgeDelegate"));
  }

  NSArray *catalog() {
    const auto type =
        operationClass(@"SLSBridgedCopyManagedDisplaySpacesOperation", @selector(init));
    id result = performSync([[type alloc] init]);
    require([result respondsToSelector:@selector(propertyListArray)],
            "SkyLight returned an unexpected catalog result");
    NSArray *displays = [result propertyListArray];
    require([displays isKindOfClass:NSArray.class] && displays.count,
            "SkyLight returned no managed displays");
    return displays;
  }

  NSDictionary *displayFor(NSArray *displays, std::uint64_t space) {
    for (NSDictionary *display in displays) {
      for (NSDictionary *entry in display[@"Spaces"]) {
        if ([entry[@"id64"] unsignedLongLongValue] == space) {
          return display;
        }
      }
    }

    return nil;
  }

  NSString *screenIdentifier(NSScreen *screen) {
    const auto identifier = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(identifier);
    NSString *value = uuid ? CFBridgingRelease(CFUUIDCreateString(nullptr, uuid)) : nil;

    if (uuid) {
      CFRelease(uuid);
    }

    return value;
  }

  NSScreen *screenFor(NSString *identifier) {
    for (NSScreen *screen in NSScreen.screens) {
      if ([screenIdentifier(screen) isEqual:identifier] ||
          ([identifier isEqual:@"Main"] &&
           [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == CGMainDisplayID())) {
        return screen;
      }
    }

    return nil;
  }

} // namespace

struct SpacesProbe::Impl {
  std::atomic<unsigned> mission_control_entries{0};
  NSMutableArray<NSWindow *> *windows = [NSMutableArray array];

  static void notification(std::uint32_t type, void *, std::size_t, void *context, int) {
    if (type == mission_control_enter) {
      static_cast<Impl *>(context)->mission_control_entries.fetch_add(1, std::memory_order_relaxed);
    }
  }

  Impl() {
    auto &bridge = Bridge::shared();
    require(bridge.observe(bridge.connection(), notification, mission_control_enter, this) ==
                kCGErrorSuccess,
            "Could not observe Mission Control entry");
  }

  ~Impl() {
    auto &bridge = Bridge::shared();
    bridge.unobserve(bridge.connection(), notification, mission_control_enter, this);

    for (NSWindow *window in windows) {
      [window close];
    }
  }
};

SpacesProbe::SpacesProbe()
    : impl_(std::make_unique<Impl>()) {}

SpacesProbe::~SpacesProbe() = default;

std::uint32_t SpacesProbe::showWindow(std::uint64_t space) {
  NSDictionary *display = displayFor(catalog(), space);
  NSScreen *screen = screenFor(display[@"Display Identifier"]);
  require(screen && [display[@"Current Space"][@"id64"] unsignedLongLongValue] == space,
          "The probe window requires a visible Space on an attached display");
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(screen.frame.origin.x + 100,
                                                                      screen.frame.origin.y + 100,
                                                                      260,
                                                                      60)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  window.title = @"Telar Spaces debug probe";
  [impl_->windows addObject:window];
  [window orderFront:nil];
  return static_cast<std::uint32_t>(window.windowNumber);
}

bool SpacesProbe::windowVisible(std::uint32_t identifier) const {
  NSArray *windows = CFBridgingRelease(
      CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));

  for (NSDictionary *window in windows) {
    if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == identifier) {
      return true;
    }
  }

  return false;
}

bool SpacesProbe::windowInSpace(std::uint32_t window, std::uint64_t space) const {
  const auto type = operationClass(@"SLSBridgedCopySpacesForWindowsOperation",
                                   @selector(initWithOptions:windows:));
  id result = performSync([[type alloc] initWithOptions:all_window_spaces windows:@[ @(window) ]]);
  require([result respondsToSelector:@selector(numbers)],
          "SkyLight returned an unexpected window membership result");
  return [[result numbers] containsObject:@(space)];
}

unsigned SpacesProbe::missionControlEntries() const {
  return impl_->mission_control_entries.load(std::memory_order_relaxed);
}
