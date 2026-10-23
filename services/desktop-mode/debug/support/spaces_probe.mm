#include "spaces_probe.hpp"
#include "native-backends/macos/spaces_bridge.hpp"
#include "native-backends/macos/virtual_spaces.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <dlfcn.h>
#include <stdexcept>

namespace {
  constexpr std::uint32_t mission_control_enter = 1204;

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

  NSScreen *screenFor(std::uint32_t display) {
    for (NSScreen *screen in NSScreen.screens) {
      if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) {
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
  auto &spaces = macos::spaces::VirtualSpaces::get();
  NSScreen *screen = screenFor(spaces.display(space));
  require(screen, "The probe window requires a Space on an attached display");
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
  const std::uint32_t windows[] = {static_cast<std::uint32_t>(window.windowNumber)};
  macos::spaces::moveToLayer(windows, spaces.stage(space));
  return windows[0];
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
  return macos::spaces::spaceOf(window) == space;
}

unsigned SpacesProbe::missionControlEntries() const {
  return impl_->mission_control_entries.load(std::memory_order_relaxed);
}
