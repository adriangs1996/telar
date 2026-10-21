#include "spaces_bridge.hpp"
#include "native-backends/desktop.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#include <QTimer>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <dlfcn.h>
#include <set>
#include <stdexcept>

// Signatures inspected in SkyLight on macOS 26.6.2. Asynchronous perform returns void.
@interface NSObject (TelarDebugSpacesBridge)
- (instancetype)initWithOptions:(unsigned)options values:(NSDictionary *)values;
- (instancetype)initWithSpaceID:(uint64_t)space;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithOptions:(unsigned)options windows:(NSArray *)windows;
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)space;
- (instancetype)initWithSpaceID:(uint64_t)space
              displayIdentifier:(NSString *)display
                          index:(unsigned)index;
- (uint64_t)spaceID;
- (NSArray *)propertyListArray;
- (NSArray *)numbers;
@end

namespace {
  using Clock = std::chrono::steady_clock;
  using namespace std::chrono_literals;
  constexpr auto operation_timeout = 5s;
  constexpr std::uint32_t mission_control_enter = 1204;
  constexpr unsigned all_window_spaces = 7;

  void require(bool condition, const char *message) {
    if (!condition) {
      throw std::runtime_error(message);
    }
  }

  struct Bridge {
    bool hold_creation_confirmation = false;
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_NOW | RTLD_LOCAL);
    using Notification = void (*)(std::uint32_t, void *, std::size_t, void *, int);
    int (*connection)() = load<decltype(connection)>("SLSMainConnectionID");
    CFStringRef (*activeDisplay)(int) =
        load<decltype(activeDisplay)>("SLSCopyActiveMenuBarDisplayIdentifier");
    CGError (*focusDisplay)(int, CFStringRef, CFStringRef) =
        load<decltype(focusDisplay)>("SLSSetActiveMenuBarDisplayIdentifier");
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
      require(library && connection && activeDisplay && focusDisplay && observe && unobserve,
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

  void performAsync(id operation) {
    require(operation != nil, "SkyLight did not initialize an asynchronous operation");
    reinterpret_cast<void (*)(id, SEL)>(
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

  void destroy(std::uint64_t space) {
    const auto type =
        operationClass(@"SLSBridgedSpaceDestroyOperation", @selector(initWithSpaceID:));
    performAsync([[type alloc] initWithSpaceID:space]);
  }

  void switchSpace(std::uint64_t space) {
    NSDictionary *display = displayFor(catalog(), space);
    require(display != nil, "The requested Space no longer exists");
    const auto previous = [display[@"Current Space"][@"id64"] unsignedLongLongValue];
    NSString *identifier = display[@"Display Identifier"];
    const auto show = operationClass(@"SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
    const auto hide = operationClass(@"SLSBridgedHideSpacesOperation", @selector(initWithSpaces:));
    const auto current = operationClass(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                        @selector(initWithDisplayIdentifier:spaceID:));

    if (previous != space) {
      performAsync([[show alloc] initWithSpaces:@[ @(space) ]]);
      performAsync([[hide alloc] initWithSpaces:@[ @(previous) ]]);
      performAsync([[current alloc] initWithDisplayIdentifier:identifier spaceID:space]);
    }

    auto &bridge = Bridge::shared();
    require(bridge.focusDisplay(bridge.connection(),
                                (__bridge CFStringRef)identifier,
                                (__bridge CFStringRef)identifier) == kCGErrorSuccess,
            "macOS could not activate the target display");
  }
} // namespace

// Only spaces_dbg links these NativeDesktop definitions; production keeps its own backend.
struct NativeDesktop::Impl {
  Sink publish;
  QTimer timer;
  DesktopState previous;
  std::optional<SpaceOperation> pending;
  std::optional<SpaceCompletion> completion;
  std::set<std::uint64_t> owned;
  std::uint64_t target = 0;
  Clock::time_point deadline;
  bool relocated = false;
  std::string error;

  Impl() {
    Bridge::shared();
    QObject::connect(&timer, &QTimer::timeout, &timer, [this] {
      refresh();
    });
  }

  DesktopState snapshot() {
    DesktopState state;
    state.accessibility = AXIsProcessTrusted();
    auto &bridge = Bridge::shared();
    NSString *focused = CFBridgingRelease(bridge.activeDisplay(bridge.connection()));
    std::uint32_t index = 0;

    for (NSDictionary *display in catalog()) {
      NSString *identifier = display[@"Display Identifier"];
      NSScreen *screen = screenFor(identifier);
      require(screen != nil, "A managed display has no corresponding NSScreen");
      const auto display_id = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
      const auto bounds = CGDisplayBounds(display_id);
      const auto current = [display[@"Current Space"][@"id64"] unsignedLongLongValue];
      const bool active = [identifier isEqual:focused];
      state.displays.push_back({display_id,
                                identifier.UTF8String,
                                bounds.origin.x,
                                bounds.origin.y,
                                bounds.size.width,
                                bounds.size.height});

      if (active) {
        state.focused_space = current;
      }

      for (NSDictionary *entry in display[@"Spaces"]) {
        const auto space = [entry[@"id64"] unsignedLongLongValue];
        state.spaces.push_back(
            {.id = space,
             .uuid = std::string(identifier.UTF8String) + ":" + std::to_string(space),
             .display = display_id,
             .index = ++index,
             .visible = space == current,
             .focused = active && space == current,
             .fullscreen = [entry[@"type"] intValue] != 0});
      }
    }

    state.available = !state.spaces.empty();
    return state;
  }

  void finish(bool succeeded, std::string message = {}) {
    completion = SpaceCompletion{*pending, succeeded, std::move(message)};
    error = completion->error;
    pending.reset();
  }

  void advance(const DesktopState &state) {
    if (!pending) {
      return;
    }

    // The debug runner can close a workspace before its native creation result reaches App.
    if (pending->kind == SpaceOperation::Kind::create &&
        Bridge::shared().hold_creation_confirmation) {
      return;
    }

    const auto found = std::ranges::find(state.spaces, pending->space, &DesktopSpace::id);

    if (pending->kind == SpaceOperation::Kind::remove && found == state.spaces.end()) {
      owned.erase(pending->space);
      finish(true);
    } else if (pending->kind == SpaceOperation::Kind::create && found != state.spaces.end()) {
      if (found->display == pending->display) {
        finish(true);
      } else if (!relocated) {
        const auto display =
            std::ranges::find(state.displays, pending->display, &DesktopDisplay::id);
        require(display != state.displays.end(),
                "The requested display disappeared during creation");
        const auto type = operationClass(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation",
                                         @selector(initWithSpaceID:displayIdentifier:index:));
        const auto count = static_cast<unsigned>(
            std::ranges::count(state.spaces, display->id, &DesktopSpace::display));
        performAsync([[type alloc]
              initWithSpaceID:pending->space
            displayIdentifier:[NSString stringWithUTF8String:display->uuid.c_str()]
                        index:count]);
        relocated = true;
      }
    }

    if (pending && Clock::now() >= deadline) {
      finish(false, "Timed out waiting for the SkyLight bridge operation");
    }
  }

  void refresh() {
    if (!publish) {
      return;
    }

    DesktopState state;

    try {
      state = snapshot();
      advance(state);

      if (target && state.focused_space == target) {
        target = 0;
      } else if (target && Clock::now() >= deadline) {
        target = 0;
        error = "Timed out switching the active Space through SkyLight";
      }
    } catch (const std::exception &exception) {
      error = exception.what();
      target = 0;

      if (pending) {
        finish(false, error);
      }
    }

    state.pending_operation = pending;
    state.completed_operation = completion;
    state.pending_space = target;
    state.error = error;

    if (state != previous && publish(state)) {
      previous = std::move(state);
    }
  }
};

NativeDesktop::NativeDesktop()
    : impl_(std::make_unique<Impl>()) {}

NativeDesktop::~NativeDesktop() {
  stop();

  // Even a failed reconciliation may leave an unassociated new Space; only remove our own IDs.
  for (const auto space : impl_->owned) {
    try {
      if (displayFor(catalog(), space)) {
        destroy(space);
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr,
                   "[CLEANUP] Space %llu: %s\n",
                   static_cast<unsigned long long>(space),
                   error.what());
    }
  }
}

void NativeDesktop::start(Sink publish) {
  stop();
  impl_->publish = std::move(publish);
  impl_->timer.start(20ms);
  impl_->refresh();
}

void NativeDesktop::stop() {
  impl_->timer.stop();
  impl_->publish = {};
  impl_->previous = {};
}

void NativeDesktop::activate(std::uint64_t space) {
  require(!impl_->pending && !impl_->target, "Another debug Space operation is pending");
  switchSpace(space);
  impl_->error.clear();
  impl_->target = space;
  impl_->deadline = Clock::now() + operation_timeout;
  impl_->refresh();
}

void NativeDesktop::changeSpace(SpaceOperation operation) {
  require(!impl_->pending && !impl_->target, "Another debug Space operation is pending");
  impl_->pending = operation;
  impl_->deadline = Clock::now() + operation_timeout;
  impl_->relocated = false;
  impl_->error.clear();

  try {
    const auto state = impl_->snapshot();
    require(std::ranges::find(state.displays, operation.display, &DesktopDisplay::id) !=
                state.displays.end(),
            "The target display is unavailable");

    if (operation.kind == SpaceOperation::Kind::create) {
      const auto type =
          operationClass(@"SLSBridgedSpaceCreateOperation", @selector(initWithOptions:values:));
      id result = performSync([[type alloc] initWithOptions:0 values:@{}]);
      require([result respondsToSelector:@selector(spaceID)],
              "SkyLight returned an unexpected create result");
      const auto created = [result spaceID];
      require(created &&
                  std::ranges::find(state.spaces, created, &DesktopSpace::id) == state.spaces.end(),
              "SkyLight did not return a new Space ID");
      impl_->owned.insert(created);
      impl_->pending->space = created;
    } else {
      const auto found = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);
      require(impl_->owned.contains(operation.space),
              "The debug backend will only remove Spaces created by this run");
      require(found != state.spaces.end() && !found->fullscreen,
              "Only an existing ordinary Space can be removed");
      require(std::ranges::count_if(state.spaces,
                                    [&](const auto &space) {
                                      return space.display == found->display && !space.fullscreen;
                                    }) > 1,
              "Each display must retain at least one ordinary Space");
      destroy(operation.space);
    }
  } catch (const std::exception &error) {
    impl_->finish(false, error.what());
  }

  // Publish the in-flight operation before polling completion, including synchronous creation.
  auto state = impl_->snapshot();
  state.pending_operation = impl_->pending;
  state.completed_operation = impl_->completion;
  state.error = impl_->error;
  impl_->publish(std::move(state));
}

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

void SpacesProbe::holdCreationConfirmation(bool hold) {
  Bridge::shared().hold_creation_confirmation = hold;
}
