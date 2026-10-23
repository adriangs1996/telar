#include "spaces_bridge.hpp"
#include "window_managers.hpp"
#include "../../trace.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <algorithm>
#include <array>
#include <dlfcn.h>
#include <libproc.h>
#include <set>
#include <span>
#include <stdexcept>
#include <unistd.h>

// Signatures inspected in SkyLight on macOS 26.6.2. Asynchronous perform returns void.
@interface NSObject (TelarSpacesBridge)
- (instancetype)initWithOptions:(unsigned)options values:(NSDictionary *)values;
- (instancetype)initWithSpaceID:(uint64_t)space;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithSpaceID:(uint64_t)space level:(int)level;
- (instancetype)initWithSpaceID:(uint64_t)space values:(NSDictionary *)values;
- (instancetype)initWithSpaceID:(uint64_t)space
                        windows:(NSArray *)windows
                        options:(unsigned)options;
- (instancetype)initWithWindows:(NSArray *)windows spaces:(NSArray *)spaces;
- (uint64_t)spaceID;
- (NSDictionary *)propertyListDictionary;
@end

namespace {
  constexpr std::size_t space_limit = 512;
  constexpr std::uint32_t display_limit = 32;
  // SpaceCreate option: an unmanaged Space, which Mission Control does not list.
  constexpr unsigned unmanaged_space = 0x1;
  // SpaceAddWindowsAndRemoveFromSpaces option: out of every Space the window was in.
  constexpr unsigned every_space = 7;
  // SLSCopySpacesForWindows mask that includes unmanaged Spaces.
  constexpr int any_space_kind = 0xffff;
  // The value a layer is stamped with: the Telar process that made it.
  NSString *const layer_owner_key = @"telar.process";

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
    CFStringRef (*activeDisplay)(int) =
        load<decltype(activeDisplay)>("SLSCopyActiveMenuBarDisplayIdentifier");
    CGError (*activateDisplay)(int, CFStringRef, CFStringRef) =
        load<decltype(activateDisplay)>("SLSSetActiveMenuBarDisplayIdentifier");
    CFArrayRef (*copyWindowSpaces)(int, int, CFArrayRef) =
        load<decltype(copyWindowSpaces)>("SLSCopySpacesForWindows");

    template <typename Function> Function load(const char *name) {
      return library ? reinterpret_cast<Function>(dlsym(library, name)) : nullptr;
    }

    bool available() const {
      return mainConnection && copyDisplays && activeDisplay;
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
      operationClass(@"SLSBridgedSpaceSetAbsoluteLevelOperation",
                     @selector(initWithSpaceID:level:));
      operationClass(@"SLSBridgedSpaceSetValuesOperation", @selector(initWithSpaceID:values:));
      operationClass(@"SLSBridgedSpaceCopyValuesOperation", @selector(initWithSpaceID:));
      operationClass(@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation",
                     @selector(initWithSpaceID:windows:options:));
      operationClass(@"SLSBridgedRemoveWindowsFromSpacesOperation",
                     @selector(initWithWindows:spaces:));
      return true;
    }();
    (void)available;
  }

  // Runs a bridged operation. Synchronous ones answer with a result, asynchronous ones return
  // at once, and SkyLight decides which an operation is.
  id perform(id operation) {
    SEL selector = sel_registerName("performWithWMBridgeDelegate");
    Method method = operation ? class_getInstanceMethod([operation class], selector) : nullptr;
    char encoding[8]{};

    if (method) {
      method_getReturnType(method, encoding, sizeof(encoding));
    }

    if (encoding[0] == '@') {
      return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(operation, selector);
    }

    if (encoding[0] != 'v') {
      throw std::runtime_error("SkyLight bridge operation has an unsupported return type");
    }

    reinterpret_cast<void (*)(id, SEL)>(objc_msgSend)(operation, selector);
    return nil;
  }

  NSArray *numbers(auto values) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto value : values) {
      [array addObject:@(value)];
    }

    return array;
  }

  // A process, by its identifier and the time it started, so a reused identifier is not mistaken
  // for the process that made a layer.
  NSString *processMark(pid_t pid) {
    proc_bsdinfo info{};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
      return nil;
    }

    return [NSString
        stringWithFormat:@"%d:%llu.%llu", pid, info.pbi_start_tvsec, info.pbi_start_tvusec];
  }

  bool running(NSString *mark) {
    NSString *process = [mark componentsSeparatedByString:@":"].firstObject;
    const auto pid = static_cast<pid_t>(process.intValue);
    return pid > 0 && [processMark(pid) isEqualToString:mark];
  }

  // The Spaces each window of the window server belongs to, unmanaged ones included.
  struct Membership {
    std::uint32_t window = 0;
    pid_t owner = 0;
    CGRect frame{};
    NSArray *spaces;
  };

  std::vector<Membership> memberships() {
    auto &api = skyLight();
    if (!api.copyWindowSpaces) {
      throw std::runtime_error("This macOS version does not report the Spaces of windows");
    }

    NSArray *windows =
        CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    std::vector<Membership> result;
    result.reserve(windows.count);
    for (NSDictionary *window in windows) {
      Membership entry;
      entry.window =
          static_cast<std::uint32_t>(number(window[(__bridge NSString *)kCGWindowNumber]));
      entry.owner = static_cast<pid_t>(number(window[(__bridge NSString *)kCGWindowOwnerPID]));
      id bounds = window[(__bridge NSString *)kCGWindowBounds];
      if (!entry.window || ![bounds isKindOfClass:NSDictionary.class] ||
          !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &entry.frame)) {
        continue;
      }

      entry.spaces = CFBridgingRelease(api.copyWindowSpaces(
          api.mainConnection(), any_space_kind, (__bridge CFArrayRef) @[ @(entry.window) ]));
      if (entry.spaces.count) {
        result.push_back(entry);
      }
    }

    return result;
  }

  // The desktop the display under a point shows, from the Spaces catalog; the main display's when
  // no display is there.
  std::uint64_t desktopAt(NSArray *catalog, CGPoint point) {
    std::array<CGDirectDisplayID, display_limit> identifiers{};
    std::uint32_t count = 0;
    CGGetDisplaysWithPoint(point, display_limit, identifiers.data(), &count);
    NSString *wanted = nil;
    if (count) {
      CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(identifiers[0]);
      wanted = uuid ? CFBridgingRelease(CFUUIDCreateString(nullptr, uuid)) : nil;
      if (uuid) {
        CFRelease(uuid);
      }
    }

    std::uint64_t main = 0;
    for (NSDictionary *display in catalog) {
      if (![display isKindOfClass:NSDictionary.class]) {
        continue;
      }

      id current = display[@"Current Space"];
      const auto space = [current isKindOfClass:NSDictionary.class] ? number(current[@"id64"]) : 0;
      NSString *identifier = display[@"Display Identifier"];
      if (wanted && [identifier isKindOfClass:NSString.class] &&
          [identifier caseInsensitiveCompare:wanted] == NSOrderedSame) {
        return space;
      }

      if ([identifier isEqual:@"Main"] || !main) {
        main = space;
      }
    }

    return main;
  }
} // namespace

namespace macos::spaces {
  DesktopState snapshot() {
    TELAR_TRACE("native.spaces.snapshot");
    ensureBridge();
    auto &api = skyLight();
    DesktopState state;
    state.accessibility = AXIsProcessTrusted();
    state.window_managers = macos::windowManagers();

    if (!api.available()) {
      throw std::runtime_error("This macOS version does not expose the required Spaces functions");
    }

    const int connection = api.mainConnection();
    NSArray *managed = CFBridgingRelease(api.copyDisplays(connection));

    if (![managed isKindOfClass:NSArray.class]) {
      throw std::runtime_error("macOS did not return a Spaces catalog");
    }

    // Every call is a round trip to the window server, which during a Space switch waits for its
    // animation. The catalog already holds each Space's name and type and each display's current
    // Space, so these two calls are all a snapshot makes, whatever the number of Spaces.
    NSString *focused_display = CFBridgingRelease(api.activeDisplay(connection));
    if (![focused_display isKindOfClass:NSString.class]) {
      focused_display = nil;
    }

    // CoreGraphics rather than NSScreen: the observer takes snapshots off the main thread, where
    // AppKit must not be used. Like NSScreen's, the list starts with the main display; mirrors,
    // which NSScreen leaves out, own no Space and are dropped below.
    std::array<CGDirectDisplayID, display_limit> identifiers{};
    std::uint32_t display_count = 0;
    if (CGGetActiveDisplayList(display_limit, identifiers.data(), &display_count) !=
        kCGErrorSuccess) {
      throw std::runtime_error("macOS did not list the active displays");
    }

    for (const auto id : std::span(identifiers).first(display_count)) {
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

      if ([focused_display isEqualToString:display[@"Display Identifier"]]) {
        state.focused_space = current;
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

        auto space_uuid = text(entry[@"uuid"]);

        if (space_uuid.empty()) {
          space_uuid = uuid + ":" + std::to_string(id);
        }

        state.spaces.push_back({.id = id,
                                .uuid = std::move(space_uuid),
                                .display = display_id,
                                .index = ++index,
                                .visible = current == id,
                                .focused = state.focused_space == id,
                                .fullscreen = number(entry[@"type"]) != 0});
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

  void focusDisplay(const DesktopDisplay &display) {
    TELAR_TRACE("native.spaces.focus_display");
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
      TELAR_TRACE("native.spaces.focus_display_window");
      focusDisplayWindow(display);
    }
  }

  std::uint64_t spaceOf(std::uint32_t window) {
    auto &api = skyLight();
    if (!api.mainConnection || !api.copyWindowSpaces) {
      return 0;
    }

    NSArray *spaces = CFBridgingRelease(api.copyWindowSpaces(
        api.mainConnection(), any_space_kind, (__bridge CFArrayRef) @[ @(window) ]));
    return number(spaces.firstObject);
  }

  std::uint64_t createLayer(int level) {
    TELAR_TRACE("native.spaces.create_layer");
    const auto create =
        operationClass(@"SLSBridgedSpaceCreateOperation", @selector(initWithOptions:values:));
    const auto stamp =
        operationClass(@"SLSBridgedSpaceSetValuesOperation", @selector(initWithSpaceID:values:));
    const auto order = operationClass(@"SLSBridgedSpaceSetAbsoluteLevelOperation",
                                      @selector(initWithSpaceID:level:));
    NSString *mark = processMark(getpid());
    if (!mark) {
      throw std::runtime_error("Telar cannot read its own process start time");
    }

    id result = perform([[create alloc] initWithOptions:unmanaged_space values:@{}]);
    const std::uint64_t layer =
        [result respondsToSelector:@selector(spaceID)] ? [result spaceID] : 0;
    if (!layer) {
      throw std::runtime_error("SkyLight did not return a new layer");
    }

    perform([[stamp alloc] initWithSpaceID:layer values:@{layer_owner_key : mark}]);
    perform([[order alloc] initWithSpaceID:layer level:level]);
    return layer;
  }

  void destroyLayer(std::uint64_t layer) {
    TELAR_TRACE("native.spaces.destroy_layer");
    const auto type =
        operationClass(@"SLSBridgedSpaceDestroyOperation", @selector(initWithSpaceID:));
    perform([[type alloc] initWithSpaceID:layer]);
  }

  void moveToLayer(std::span<const std::uint32_t> windows, std::uint64_t layer) {
    TELAR_TRACE("native.spaces.move_to_layer");
    if (windows.empty()) {
      return;
    }

    // Adding leaves this process's own windows in the layers they were in as well, so they are
    // taken out of those explicitly.
    auto &api = skyLight();
    NSArray *moved = numbers(windows);
    NSMutableArray *previous = [CFBridgingRelease(api.copyWindowSpaces(
        api.mainConnection(), any_space_kind, (__bridge CFArrayRef)moved)) mutableCopy];
    [previous removeObject:@(layer)];

    const auto add = operationClass(@"SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation",
                                    @selector(initWithSpaceID:windows:options:));
    perform([[add alloc] initWithSpaceID:layer windows:moved options:every_space]);
    if (previous.count) {
      const auto remove = operationClass(@"SLSBridgedRemoveWindowsFromSpacesOperation",
                                         @selector(initWithWindows:spaces:));
      perform([[remove alloc] initWithWindows:moved spaces:previous]);
    }
  }

  void showLayers(std::span<const std::uint64_t> shown, std::span<const std::uint64_t> hidden) {
    TELAR_TRACE("native.spaces.show_layers");
    if (!shown.empty()) {
      const auto show =
          operationClass(@"SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
      perform([[show alloc] initWithSpaces:numbers(shown)]);
    }

    if (!hidden.empty()) {
      const auto hide =
          operationClass(@"SLSBridgedHideSpacesOperation", @selector(initWithSpaces:));
      perform([[hide alloc] initWithSpaces:numbers(hidden)]);
    }
  }

  void evacuate(std::span<const std::uint64_t> layers) {
    TELAR_TRACE("native.spaces.evacuate");
    if (layers.empty()) {
      return;
    }

    auto &api = skyLight();
    NSArray *catalog = CFBridgingRelease(api.copyDisplays(api.mainConnection()));
    const auto self = getpid();
    for (const auto &entry : memberships()) {
      const bool inside = std::ranges::any_of(layers, [&](const auto layer) {
        return [entry.spaces containsObject:@(layer)];
      });

      if (!inside || entry.owner == self) {
        continue;
      }

      const auto desktop =
          desktopAt(catalog, CGPointMake(CGRectGetMidX(entry.frame), CGRectGetMidY(entry.frame)));
      if (desktop) {
        const std::uint32_t window[] = {entry.window};
        moveToLayer(window, desktop);
      }
    }
  }

  std::vector<std::uint64_t> strayLayers() {
    TELAR_TRACE("native.spaces.stray_layers");
    auto &api = skyLight();
    const auto copy =
        operationClass(@"SLSBridgedSpaceCopyValuesOperation", @selector(initWithSpaceID:));
    std::set<std::uint64_t> managed;
    NSArray *catalog = CFBridgingRelease(api.copyDisplays(api.mainConnection()));
    for (NSDictionary *display in catalog) {
      for (NSDictionary *space in display[@"Spaces"]) {
        managed.insert(number(space[@"id64"]));
      }
    }

    std::set<std::uint64_t> candidates;
    for (const auto &entry : memberships()) {
      for (NSNumber *space in entry.spaces) {
        if (!managed.contains(space.unsignedLongLongValue)) {
          candidates.insert(space.unsignedLongLongValue);
        }
      }
    }

    std::vector<std::uint64_t> stray;
    for (const auto candidate : candidates) {
      id result = perform([[copy alloc] initWithSpaceID:candidate]);
      NSDictionary *values = [result respondsToSelector:@selector(propertyListDictionary)]
                                 ? [result propertyListDictionary]
                                 : nil;
      id mark = [values isKindOfClass:NSDictionary.class] ? values[layer_owner_key] : nil;
      if ([mark isKindOfClass:NSString.class] && !running(mark)) {
        stray.push_back(candidate);
      }
    }

    return stray;
  }
} // namespace macos::spaces
