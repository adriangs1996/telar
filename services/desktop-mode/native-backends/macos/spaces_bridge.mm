#include "spaces_bridge.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <algorithm>
#include <dlfcn.h>
#include <stdexcept>
#include <unistd.h>

// Signatures inspected in SkyLight on macOS 26.6.2. Asynchronous perform returns void.
@interface NSObject (TelarSpacesBridge)
- (instancetype)initWithOptions:(unsigned)options values:(NSDictionary *)values;
- (instancetype)initWithSpaceID:(uint64_t)space;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)space;
- (instancetype)initWithSpaceID:(uint64_t)space
              displayIdentifier:(NSString *)display
                          index:(unsigned)index;
- (uint64_t)spaceID;
@end

namespace {
  constexpr std::size_t space_limit = 512;

  std::string text(NSString *value) {
    return [value isKindOfClass:NSString.class] ? std::string(value.UTF8String ?: "") : "";
  }

  std::uint64_t number(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value unsignedLongLongValue] : 0;
  }

  struct SkyLight {
    void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                           RTLD_NOW | RTLD_LOCAL);
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
    void (*moveWindows)(int, CFArrayRef, std::uint64_t) =
        load<decltype(moveWindows)>("SLSMoveWindowsToManagedSpace");
    CFArrayRef (*copyWindowSpaces)(int, int, CFArrayRef) =
        load<decltype(copyWindowSpaces)>("SLSCopySpacesForWindows");

    template <typename Function> Function load(const char *name) {
      return library ? reinterpret_cast<Function>(dlsym(library, name)) : nullptr;
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

  SkyLight &skyLight() {
    // Objective-C classes stay registered; keep their framework loaded for the process lifetime.
    static SkyLight api;
    return api;
  }

  Class operationClass(NSString *name, SEL initializer) {
    if (!skyLight().available()) {
      throw std::runtime_error("This macOS version does not expose the required Spaces functions");
    }

    Class type = NSClassFromString(name);

    if (!type || ![type instancesRespondToSelector:initializer] ||
        ![type instancesRespondToSelector:sel_registerName("performWithWMBridgeDelegate")]) {
      throw std::runtime_error("Unavailable SkyLight operation: " + text(name));
    }

    return type;
  }

  void ensureBridge() {
    static const bool available = [] {
      operationClass(@"SLSBridgedSpaceCreateOperation", @selector(initWithOptions:values:));
      operationClass(@"SLSBridgedSpaceDestroyOperation", @selector(initWithSpaceID:));
      operationClass(@"SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
      operationClass(@"SLSBridgedHideSpacesOperation", @selector(initWithSpaces:));
      operationClass(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                     @selector(initWithDisplayIdentifier:spaceID:));
      return true;
    }();
    (void)available;
  }

  SEL performer(id operation, char result_type) {
    SEL selector = sel_registerName("performWithWMBridgeDelegate");
    Method method = class_getInstanceMethod([operation class], selector);
    char encoding[8]{};

    if (method) {
      method_getReturnType(method, encoding, sizeof(encoding));
    }

    if (!operation || encoding[0] != result_type) {
      throw std::runtime_error("SkyLight bridge operation has an unsupported return type");
    }

    return selector;
  }

  void performAsync(id operation) {
    const auto selector = performer(operation, 'v');
    reinterpret_cast<void (*)(id, SEL)>(objc_msgSend)(operation, selector);
  }
} // namespace

namespace macos::spaces {
  void moveWindow(std::uint32_t window, std::uint64_t space) {
    auto &api = skyLight();
    if (!window || !space || !api.moveWindows || !api.copyWindowSpaces) {
      throw std::runtime_error("Window placement in Spaces is unavailable");
    }

    NSArray *windows = @[ @(window) ];
    constexpr int all_spaces = 7;
    NSArray *before = CFBridgingRelease(
        api.copyWindowSpaces(api.mainConnection(), all_spaces, (__bridge CFArrayRef)windows));
    if ([before containsObject:@(space)] && before.count == 1) {
      return;
    }
    api.moveWindows(api.mainConnection(), (__bridge CFArrayRef)windows, space);
    NSArray *after = CFBridgingRelease(
        api.copyWindowSpaces(api.mainConnection(), all_spaces, (__bridge CFArrayRef)windows));
    if (![after containsObject:@(space)]) {
      throw std::runtime_error("macOS refused to place the window in its workspace Space");
    }
  }

  DesktopState snapshot() {
    ensureBridge();
    auto &api = skyLight();
    DesktopState state;
    state.accessibility = AXIsProcessTrusted();

    if (!api.available()) {
      throw std::runtime_error("This macOS version does not expose the required Spaces functions");
    }

    const int connection = api.mainConnection();
    NSArray *managed = CFBridgingRelease(api.copyDisplays(connection));

    if (![managed isKindOfClass:NSArray.class]) {
      throw std::runtime_error("macOS did not return a Spaces catalog");
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

      if (uuid == "Main") {
        auto main = std::ranges::find(state.displays, display_id, &DesktopDisplay::id);

        if (main != state.displays.end()) {
          main->uuid = uuid;
        }

        state.focused_space = current;
      }

      for (id entry in entries) {
        if (state.spaces.size() == space_limit) {
          throw std::runtime_error("The macOS Spaces catalog exceeded the supported limit");
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

    std::erase_if(state.displays, [&](const auto &display) {
      return std::ranges::none_of(state.spaces, [&](const auto &space) {
        return space.display == display.id;
      });
    });

    state.available = !state.spaces.empty();
    return state;
  }

  std::uint64_t create() {
    const auto type =
        operationClass(@"SLSBridgedSpaceCreateOperation", @selector(initWithOptions:values:));
    id operation = [[type alloc] initWithOptions:0 values:@{}];
    id result =
        reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(operation, performer(operation, '@'));

    if (![result respondsToSelector:@selector(spaceID)] || ![result spaceID]) {
      throw std::runtime_error("SkyLight did not return a new Space ID");
    }

    return [result spaceID];
  }

  void remove(std::uint64_t space) {
    const auto type =
        operationClass(@"SLSBridgedSpaceDestroyOperation", @selector(initWithSpaceID:));
    performAsync([[type alloc] initWithSpaceID:space]);
  }

  void activate(const DesktopState &state, std::uint64_t space) {
    const auto target = std::ranges::find(state.spaces, space, &DesktopSpace::id);

    if (target == state.spaces.end()) {
      throw std::runtime_error("The requested Space no longer exists");
    }

    const auto display = std::ranges::find(state.displays, target->display, &DesktopDisplay::id);
    const auto previous = std::ranges::find_if(state.spaces, [&](const auto &entry) {
      return entry.display == target->display && entry.visible;
    });

    if (display == state.displays.end() || previous == state.spaces.end()) {
      throw std::runtime_error("The target display is unavailable");
    }

    if (previous->id == target->id) {
      return;
    }

    const auto show = operationClass(@"SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
    const auto hide = operationClass(@"SLSBridgedHideSpacesOperation", @selector(initWithSpaces:));
    const auto current = operationClass(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                                        @selector(initWithDisplayIdentifier:spaceID:));
    NSString *identifier = [NSString stringWithUTF8String:display->uuid.c_str()];
    id show_operation = [[show alloc] initWithSpaces:@[ @(space) ]];
    id hide_operation = [[hide alloc] initWithSpaces:@[ @(previous->id) ]];
    id current_operation = [[current alloc] initWithDisplayIdentifier:identifier spaceID:space];
    performer(show_operation, 'v');
    performer(hide_operation, 'v');
    performer(current_operation, 'v');

    performAsync(show_operation);
    performAsync(hide_operation);
    performAsync(current_operation);
  }

  void move(std::uint64_t space, const DesktopDisplay &display, unsigned index) {
    const auto type = operationClass(@"SLSBridgedMoveManagedSpaceToDisplayIndexOperation",
                                     @selector(initWithSpaceID:displayIdentifier:index:));
    performAsync([[type alloc] initWithSpaceID:space
                             displayIdentifier:[NSString stringWithUTF8String:display.uuid.c_str()]
                                         index:index]);
  }

  void focusDisplay(const DesktopDisplay &display) {
    auto &api = skyLight();
    NSString *identifier = [NSString stringWithUTF8String:display.uuid.c_str()];

    if (!api.activateDisplay ||
        api.activateDisplay(api.mainConnection(),
                            (__bridge CFStringRef)identifier,
                            (__bridge CFStringRef)identifier) != kCGErrorSuccess) {
      throw std::runtime_error("macOS could not focus the target display");
    }

    // Window focus is separate from Space visibility and remains optional when AX is unavailable.
    if (AXIsProcessTrusted()) {
      focusDisplayWindow(display);
    }
  }
} // namespace macos::spaces
