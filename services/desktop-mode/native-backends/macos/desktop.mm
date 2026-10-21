#include "../desktop.hpp"
#include "mission_control.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <algorithm>
#include <chrono>
#include <dlfcn.h>
#include <limits>
#include <utility>
#include <unistd.h>

namespace {
  using Clock = std::chrono::steady_clock;
  constexpr auto activation_timeout = std::chrono::seconds{4};
  constexpr auto gesture_interval = std::chrono::milliseconds{180};
  constexpr std::size_t space_limit = 512;

  // Undocumented Dock gesture fields, as investigated by yabai and InstantSpaceSwitcher.
  // See licenses/yabai.txt for the reference implementation's MIT attribution.
  enum class GestureField : std::uint32_t {
    type = 55,
    hid_type = 110,
    motion = 123,
    progress = 124,
    velocity = 129,
    phase = 132
  };
  enum class GestureValue : std::int64_t {
    began = 1,
    ended = 4,
    dock_swipe = 23,
    dock_control = 30,
    horizontal = 1
  };
  constexpr double gesture_velocity = 9999.0;

  CGEventField field(GestureField value) {
    return static_cast<CGEventField>(value);
  }

  std::string text(NSString *value) {
    return [value isKindOfClass:NSString.class] ? std::string(value.UTF8String ?: "") : "";
  }

  std::uint64_t number(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value unsignedLongLongValue] : 0;
  }

  struct SkyLight {
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_LAZY | RTLD_LOCAL);
    int (*mainConnection)() = load<decltype(mainConnection)>("SLSMainConnectionID");
    CFArrayRef (*copyDisplays)(int) = load<decltype(copyDisplays)>("SLSCopyManagedDisplaySpaces");
    std::uint64_t (*currentSpace)(int, CFStringRef) =
        load<decltype(currentSpace)>("SLSManagedDisplayGetCurrentSpace");
    CFStringRef (*activeDisplay)(int) =
        load<decltype(activeDisplay)>("SLSCopyActiveMenuBarDisplayIdentifier");
    CFStringRef (*spaceName)(int, std::uint64_t) = load<decltype(spaceName)>("SLSSpaceCopyName");
    int (*spaceType)(int, std::uint64_t) = load<decltype(spaceType)>("SLSSpaceGetType");
    CGError (*activateDisplay)(int, CFStringRef, CFStringRef) =
        load<decltype(activateDisplay)>("SLSSetActiveMenuBarDisplayIdentifier");

    template <typename Function> Function load(const char *name) {
      return library ? reinterpret_cast<Function>(dlsym(library, name)) : nullptr;
    }

    ~SkyLight() {
      if (library) {
        dlclose(library);
      }
    }

    bool available() const {
      return mainConnection && copyDisplays && currentSpace && activeDisplay && spaceName &&
             spaceType;
    }
  };

  bool focusDisplayWindow(const DesktopDisplay &display) {
    using WindowIdentifier = AXError (*)(AXUIElementRef, CGWindowID *);
    const auto identifier =
        reinterpret_cast<WindowIdentifier>(dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"));
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    if (!identifier || ![windows isKindOfClass:NSArray.class]) {
      return false;
    }

    const CGRect bounds = CGRectMake(display.x, display.y, display.width, display.height);

    for (NSDictionary *window in windows) {
      const auto pid = static_cast<pid_t>(number(window[(__bridge NSString *)kCGWindowOwnerPID]));
      CGRect frame{};
      id rectangle = window[(__bridge NSString *)kCGWindowBounds];

      if (pid == getpid() || number(window[(__bridge NSString *)kCGWindowLayer]) != 0 ||
          ![rectangle isKindOfClass:NSDictionary.class] ||
          !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)rectangle, &frame) ||
          !CGRectContainsPoint(bounds, CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)))) {
        continue;
      }

      const auto target =
          static_cast<CGWindowID>(number(window[(__bridge NSString *)kCGWindowNumber]));
      AXUIElementRef application = AXUIElementCreateApplication(pid);
      AXUIElementSetMessagingTimeout(application, 0.2f);
      CFTypeRef elements = nullptr;
      bool raised = false;

      if (AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &elements) ==
              kAXErrorSuccess &&
          elements && CFGetTypeID(elements) == CFArrayGetTypeID()) {
        const auto list = static_cast<CFArrayRef>(elements);

        for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
          auto element =
              static_cast<AXUIElementRef>(const_cast<void *>(CFArrayGetValueAtIndex(list, index)));
          CGWindowID window_id = 0;

          if (identifier(element, &window_id) == kAXErrorSuccess && window_id == target) {
            [[NSRunningApplication runningApplicationWithProcessIdentifier:pid]
                activateWithOptions:0];
            AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute, element);
            raised = AXUIElementPerformAction(element, kAXRaiseAction) == kAXErrorSuccess;
            break;
          }
        }
      }

      if (elements) {
        CFRelease(elements);
      }

      CFRelease(application);

      if (raised) {
        return true;
      }

      // Do not activate several unrelated applications when the front window rejects AX focus.
      return false;
    }

    return false;
  }
} // namespace

struct NativeDesktop::Impl {
  SkyLight api;
  MissionControl mission_control;
  std::optional<SpaceCompletion> completion;
  Sink publish;
  DesktopState previous;
  DesktopState latest;
  NSMutableArray *observers = [NSMutableArray array];
  NSTimer *timer = nil;
  std::uint64_t target = 0;
  std::uint64_t gesture_origin = 0;
  bool display_activation_sent = false;
  Clock::time_point deadline;
  Clock::time_point next_gesture;
  std::string error;

  void stop() {
    mission_control.cancel();
    [timer invalidate];
    timer = nil;

    for (id observer in observers) {
      [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
      [NSNotificationCenter.defaultCenter removeObserver:observer];
    }

    [observers removeAllObjects];
    target = 0;
    previous = {};
    publish = {};
  }

  void watch(NSNotificationCenter *center, NSNotificationName name) {
    id token = [center addObserverForName:name
                                   object:nil
                                    queue:NSOperationQueue.mainQueue
                               usingBlock:^(NSNotification *) {
                                 refresh();
                               }];
    [observers addObject:token];
  }

  DesktopState snapshot() {
    DesktopState state;
    state.accessibility = AXIsProcessTrusted();

    if (!api.available()) {
      state.error = "This macOS version does not expose the required Spaces functions";
      return state;
    }

    const int connection = api.mainConnection();
    NSArray *managed = CFBridgingRelease(api.copyDisplays(connection));

    if (![managed isKindOfClass:NSArray.class]) {
      state.error = "macOS did not return a Spaces catalog";
      return state;
    }

    NSString *focused_display = CFBridgingRelease(api.activeDisplay(connection));
    state.focused_space = [focused_display isKindOfClass:NSString.class]
                              ? api.currentSpace(connection, (__bridge CFStringRef)focused_display)
                              : 0;

    for (NSScreen *screen in NSScreen.screens) {
      const auto id =
          static_cast<CGDirectDisplayID>(number(screen.deviceDescription[@"NSScreenNumber"]));
      CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(id);
      NSString *identifier = uuid ? CFBridgingRelease(CFUUIDCreateString(nullptr, uuid)) : nil;

      if (uuid) {
        CFRelease(uuid);
      }

      const auto frame = CGDisplayBounds(id);
      state.displays.push_back({id,
                                text(identifier),
                                frame.origin.x,
                                frame.origin.y,
                                frame.size.width,
                                frame.size.height});
    }

    std::uint32_t index = 0;

    for (id value in managed) {
      if (![value isKindOfClass:NSDictionary.class]) {
        continue;
      }

      NSDictionary *display = value;
      const auto uuid = text(display[@"Display Identifier"]);
      const auto found = std::ranges::find(state.displays, uuid, &DesktopDisplay::uuid);
      const auto display_id = uuid == "Main"                  ? CGMainDisplayID()
                              : found == state.displays.end() ? 0
                                                              : found->id;
      id current_entry = display[@"Current Space"];
      const auto current =
          [current_entry isKindOfClass:NSDictionary.class] ? number(current_entry[@"id64"]) : 0;
      id entries = display[@"Spaces"];

      if (!display_id || ![entries isKindOfClass:NSArray.class]) {
        continue;
      }

      for (id entry in entries) {
        if (state.spaces.size() == space_limit) {
          state.error = "The macOS Spaces catalog exceeded the supported limit";
          return state;
        }

        if (![entry isKindOfClass:NSDictionary.class]) {
          continue;
        }

        const auto id = number(entry[@"id64"]);

        if (!id) {
          continue;
        }

        NSString *name = CFBridgingRelease(api.spaceName(connection, id));
        auto space_uuid = text(name);

        if (space_uuid.empty()) {
          space_uuid = uuid + ":" + std::to_string(id);
        }

        state.spaces.push_back({.id = id,
                                .uuid = std::move(space_uuid),
                                .display = display_id,
                                .index = ++index,
                                .visible = current == id,
                                .focused = state.focused_space == id,
                                .fullscreen = api.spaceType(connection, id) != 0});
      }
    }

    state.available = !state.spaces.empty();
    return state;
  }

  bool gesture(const DesktopSpace &destination) {
    const auto current = std::ranges::find_if(latest.spaces, [&](const auto &space) {
      return space.display == destination.display && space.visible;
    });
    const auto display =
        std::ranges::find(latest.displays, destination.display, &DesktopDisplay::id);

    if (current == latest.spaces.end() || display == latest.displays.end()) {
      error = "The target display is no longer available";
      return false;
    }

    if (current->id == destination.id) {
      if (!display_activation_sent) {
        NSString *uuid = [NSString stringWithUTF8String:display->uuid.c_str()];

        if (!api.activateDisplay ||
            api.activateDisplay(api.mainConnection(),
                                (__bridge CFStringRef)uuid,
                                (__bridge CFStringRef)uuid) != kCGErrorSuccess) {
          error = "macOS could not focus the target display";
          return false;
        }

        focusDisplayWindow(*display);
        display_activation_sent = true;
      }

      return true;
    }

    // Wait for the observed hop before issuing another one. Reposting while Dock is
    // animating can overshoot the destination or repeatedly reverse the transition.
    if (gesture_origin == current->id) {
      return true;
    }

    CGEventRef event = CGEventCreate(nullptr);

    if (!event) {
      error = "Could not create a macOS Space activation gesture";
      return false;
    }

    const auto cursor = CGEventGetLocation(event);
    const CGPoint center{display->x + display->width / 2, display->y + display->height / 2};
    const double direction = destination.index > current->index ? 1.0 : -1.0;
    CGWarpMouseCursorPosition(center);
    CGEventSetLocation(event, center);
    CGEventSetIntegerValueField(event,
                                field(GestureField::type),
                                static_cast<int>(GestureValue::dock_control));
    CGEventSetIntegerValueField(event,
                                field(GestureField::hid_type),
                                static_cast<int>(GestureValue::dock_swipe));
    CGEventSetIntegerValueField(event,
                                field(GestureField::motion),
                                static_cast<int>(GestureValue::horizontal));
    CGEventSetDoubleValueField(event, field(GestureField::progress), direction);
    CGEventSetDoubleValueField(event, field(GestureField::velocity), direction * gesture_velocity);
    CGEventSetIntegerValueField(event,
                                field(GestureField::phase),
                                static_cast<int>(GestureValue::began));
    CGEventPost(kCGSessionEventTap, event);
    CGEventSetIntegerValueField(event,
                                field(GestureField::phase),
                                static_cast<int>(GestureValue::ended));
    CGEventPost(kCGSessionEventTap, event);
    CFRelease(event);
    CGWarpMouseCursorPosition(cursor);
    gesture_origin = current->id;
    display_activation_sent = false;
    return true;
  }

  void refresh() {
    if (!publish) {
      return;
    }

    latest = snapshot();
    bool activation_failed = false;

    if (target) {
      const auto destination = std::ranges::find(latest.spaces, target, &DesktopSpace::id);

      if (latest.focused_space == target) {
        target = 0;
        error.clear();
      } else if (destination == latest.spaces.end() || Clock::now() >= deadline) {
        target = 0;
        error = "macOS did not activate the requested Space";
        activation_failed = true;
      } else if (Clock::now() >= next_gesture && mission_control.readyForActivation()) {
        if (!gesture(*destination)) {
          target = 0;
          activation_failed = true;
        }

        next_gesture = Clock::now() + gesture_interval;
      }
    }

    if (activation_failed && mission_control.pending()) {
      completion = SpaceCompletion{*mission_control.pending(), false, error};
      mission_control.cancel();
    } else if (!target) {
      if (auto result = mission_control.advance(latest)) {
        completion = std::move(result);
        error = completion->error;
      }
    }

    latest.pending_space = target;
    latest.pending_operation = mission_control.pending();
    latest.completed_operation = completion;

    if (!error.empty()) {
      latest.error = error;
    }

    if (latest != previous && publish(latest)) {
      previous = latest;
    }

    // Notifications drive focus changes. A slow fallback also catches Mission Control reordering
    // and Accessibility changes, neither of which has a complete public notification stream.
    [timer invalidate];
    timer = [NSTimer scheduledTimerWithTimeInterval:target || mission_control.pending() ? 0.08 : 2.0
                                            repeats:NO
                                              block:^(NSTimer *) {
                                                refresh();
                                              }];
  }
};

NativeDesktop::NativeDesktop()
    : impl_(std::make_unique<Impl>()) {}

NativeDesktop::~NativeDesktop() {
  stop();
}

void NativeDesktop::start(Sink publish) {
  stop();
  impl_->publish = std::move(publish);
  auto *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
  impl_->watch(workspace, NSWorkspaceActiveSpaceDidChangeNotification);
  impl_->watch(workspace, NSWorkspaceDidActivateApplicationNotification);
  impl_->watch(workspace, NSWorkspaceDidWakeNotification);
  impl_->watch(workspace, NSWorkspaceDidLaunchApplicationNotification);
  impl_->watch(NSNotificationCenter.defaultCenter,
               NSApplicationDidChangeScreenParametersNotification);
  impl_->refresh();
}

void NativeDesktop::stop() {
  impl_->stop();
}

void NativeDesktop::activate(std::uint64_t space) {
  if (impl_->mission_control.pending()) {
    impl_->error = "Wait for the current Space operation to finish";
    impl_->refresh();
    return;
  }

  impl_->error.clear();

  if (!AXIsProcessTrusted()) {
    impl_->error = "Allow Telar Desktop in System Settings > Privacy & Security > Accessibility";
    impl_->refresh();
    return;
  }

  impl_->target = space;
  impl_->gesture_origin = 0;
  impl_->display_activation_sent = false;
  impl_->deadline = Clock::now() + activation_timeout;
  impl_->next_gesture = {};
  impl_->refresh();
}

void NativeDesktop::changeSpace(SpaceOperation operation) {
  auto state = impl_->snapshot();
  std::string error;

  if (impl_->mission_control.pending() || impl_->target) {
    error = "Another Space operation is in progress";
  } else if (!state.available || !state.accessibility) {
    error = "Space changes require Accessibility permission and an available macOS Spaces catalog";
  } else if (operation.kind == SpaceOperation::Kind::remove) {
    const auto target = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);

    if (target == state.spaces.end() || target->fullscreen) {
      error = "Only an existing ordinary Space can be removed";
    } else {
      operation.display = target->display;
      const auto ordinary = std::ranges::count_if(state.spaces, [&](const auto &space) {
        return space.display == target->display && !space.fullscreen;
      });

      if (ordinary <= 1) {
        error = "macOS must keep at least one ordinary Space on each display";
      } else if (target->visible) {
        const auto distance = [&](const DesktopSpace &space) {
          if (space.display != target->display || space.fullscreen || space.id == target->id) {
            return std::numeric_limits<std::uint32_t>::max();
          }

          return space.index > target->index ? space.index - target->index
                                             : target->index - space.index;
        };
        const auto fallback = std::ranges::min_element(state.spaces, {}, distance);
        impl_->target = fallback->id;
        impl_->deadline = Clock::now() + activation_timeout;
        impl_->next_gesture = {};
        impl_->gesture_origin = 0;
        impl_->display_activation_sent = false;
      }
    }
  }

  if (error.empty() && !std::ranges::any_of(state.displays, [&](const auto &display) {
        return display.id == operation.display;
      })) {
    error = "The target display is not available";
  }

  impl_->error = error;

  if (error.empty()) {
    impl_->mission_control.begin(operation, state);
  } else {
    impl_->completion = SpaceCompletion{operation, false, std::move(error)};
  }

  impl_->refresh();
}
