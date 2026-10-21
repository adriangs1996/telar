#include "mission_control.hpp"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <algorithm>
#include <chrono>
#include <dlfcn.h>
#include <set>
#include <utility>

namespace {
  using Clock = std::chrono::steady_clock;
  constexpr auto operation_timeout = std::chrono::seconds{8};
  constexpr auto control_settle_time = std::chrono::milliseconds{300};
  constexpr CFIndex maximum_children = 512;

  struct CFValue {
    CFTypeRef value;

    explicit CFValue(CFTypeRef value = nullptr)
        : value(value) {}

    CFValue(const CFValue &) = delete;
    CFValue &operator=(const CFValue &) = delete;

    ~CFValue() {
      if (value) {
        CFRelease(value);
      }
    }

    AXUIElementRef element() const {
      return value && CFGetTypeID(value) == AXUIElementGetTypeID()
                 ? static_cast<AXUIElementRef>(const_cast<void *>(value))
                 : nullptr;
    }
  };

  CFValue attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = nullptr;

    if (element) {
      AXUIElementCopyAttributeValue(element, name, &value);
    }

    return CFValue(value);
  }

  bool matches(AXUIElementRef element, CFStringRef identifier) {
    const auto value = attribute(element, CFSTR("AXIdentifier"));
    return value.value && CFEqual(value.value, identifier);
  }

  CFValue child(AXUIElementRef parent, CFStringRef identifier, std::uint32_t display = 0) {
    const auto children = attribute(parent, kAXChildrenAttribute);

    if (!children.value || CFGetTypeID(children.value) != CFArrayGetTypeID()) {
      return CFValue();
    }

    const auto list = static_cast<CFArrayRef>(children.value);

    for (CFIndex index = 0; index < std::min(CFArrayGetCount(list), maximum_children); ++index) {
      const auto value = CFArrayGetValueAtIndex(list, index);

      if (CFGetTypeID(value) != AXUIElementGetTypeID()) {
        continue;
      }

      auto element = static_cast<AXUIElementRef>(const_cast<void *>(value));

      if (!matches(element, identifier)) {
        continue;
      }

      if (display) {
        const auto number = attribute(element, CFSTR("AXDisplayID"));
        std::int64_t id = 0;

        if (!number.value || CFGetTypeID(number.value) != CFNumberGetTypeID() ||
            !CFNumberGetValue(static_cast<CFNumberRef>(number.value), kCFNumberSInt64Type, &id) ||
            id != display) {
          continue;
        }
      }

      return CFValue(CFRetain(element));
    }

    return CFValue();
  }
} // namespace

struct MissionControl::Impl {
  using Toggle = CGError (*)(CFStringRef, int);
  Toggle toggle = reinterpret_cast<Toggle>(dlsym(RTLD_DEFAULT, "CoreDockSendNotification"));
  std::optional<SpaceOperation> operation;
  std::set<std::uint64_t> previous_spaces;
  std::string target_uuid;
  Clock::time_point deadline;
  Clock::time_point opened_at;
  Clock::time_point last_closed;
  AXUIElementRef dock = nullptr;
  bool opened = false;
  bool acted = false;

  void cancel() {
    if (opened && toggle && dock) {
      const auto group = child(dock, CFSTR("mc"));

      if (group.element()) {
        toggle(CFSTR("com.apple.expose.awake"), 0);
        last_closed = Clock::now();
      }
    }

    if (dock) {
      CFRelease(dock);
      dock = nullptr;
    }

    operation.reset();
    previous_spaces.clear();
    opened = false;
    acted = false;
  }

  SpaceCompletion finish(bool succeeded, std::string error = {}, std::uint64_t space = 0) {
    SpaceCompletion result{*operation, succeeded, std::move(error)};

    if (space) {
      result.operation.space = space;
    }

    cancel();
    return result;
  }

  std::optional<SpaceCompletion> observe(const DesktopState &state) {
    if (operation->kind == SpaceOperation::Kind::remove) {
      const auto found = std::ranges::find(state.spaces, operation->space, &DesktopSpace::id);

      if (found == state.spaces.end()) {
        return finish(true);
      }

      if (found->uuid != target_uuid) {
        return finish(false, "The Space identity changed before removal");
      }

      if (found->fullscreen || std::ranges::count_if(state.spaces, [&](const auto &space) {
                                 return space.display == found->display && !space.fullscreen;
                               }) <= 1) {
        return finish(false, "The last ordinary Space and fullscreen Spaces cannot be removed");
      }

      return {};
    }

    if (!acted) {
      return {};
    }

    std::uint64_t created = 0;

    for (const auto &space : state.spaces) {
      if (space.display != operation->display || space.fullscreen ||
          previous_spaces.contains(space.id)) {
        continue;
      }

      if (created) {
        return finish(false,
                      "Several Spaces appeared concurrently; no automatic association was made");
      }

      created = space.id;
    }

    return created ? std::optional{finish(true, {}, created)} : std::nullopt;
  }

  std::optional<SpaceCompletion> advance(const DesktopState &state) {
    if (!operation) {
      return {};
    }

    if (!state.available) {
      return Clock::now() >= deadline
                 ? std::optional{finish(false, "The macOS Spaces catalog became unavailable")}
                 : std::nullopt;
    }

    if (!std::ranges::any_of(state.displays, [&](const auto &display) {
          return display.id == operation->display;
        })) {
      return finish(false, "The target display disconnected");
    }

    if (auto completion = observe(state)) {
      return completion;
    }

    if (Clock::now() >= deadline) {
      return finish(false, "Timed out waiting for Mission Control to change the Spaces catalog");
    }

    if (!state.accessibility || !toggle) {
      return finish(false, "Mission Control requires Accessibility permission and Dock support");
    }

    if (operation->kind == SpaceOperation::Kind::remove) {
      const auto target = std::ranges::find(state.spaces, operation->space, &DesktopSpace::id);

      if (target != state.spaces.end() && target->visible) {
        return {};
      }
    }

    if (!dock) {
      if (Clock::now() - last_closed < control_settle_time) {
        return {};
      }
      NSRunningApplication *application =
          [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"]
              .firstObject;

      if (!application) {
        return finish(false, "The macOS Dock is not running");
      }

      dock = AXUIElementCreateApplication(application.processIdentifier);
      AXUIElementSetMessagingTimeout(dock, 0.2f);
      const auto existing = child(dock, CFSTR("mc"));

      if (existing.element()) {
        return finish(false, "Close Mission Control before requesting a Space change");
      }

      if (toggle(CFSTR("com.apple.expose.awake"), 0) != kCGErrorSuccess) {
        return finish(false, "macOS rejected opening Mission Control");
      }

      opened = true;
      opened_at = Clock::now();
      return {};
    }

    if (acted || Clock::now() - opened_at < control_settle_time) {
      return {};
    }

    const auto group = child(dock, CFSTR("mc"));
    const auto display = child(group.element(), CFSTR("mc.display"), operation->display);
    const auto spaces = child(display.element(), CFSTR("mc.spaces"));

    if (!spaces.element()) {
      return {};
    }

    if (operation->kind == SpaceOperation::Kind::create) {
      const auto add = child(spaces.element(), CFSTR("mc.spaces.add"));
      const auto enabled = attribute(add.element(), kAXEnabledAttribute);

      if (!add.element()) {
        return {};
      }

      if (enabled.value && CFEqual(enabled.value, kCFBooleanFalse)) {
        return finish(false, "macOS does not allow another Space on this display");
      }

      if (AXUIElementPerformAction(add.element(), kAXPressAction) != kAXErrorSuccess) {
        return finish(false, "macOS rejected creating the Space");
      }
    } else {
      const auto list = child(spaces.element(), CFSTR("mc.spaces.list"));
      const auto children = attribute(list.element(), kAXChildrenAttribute);
      std::size_t position = 0;
      std::size_t count = 0;

      for (const auto &space : state.spaces) {
        if (space.display == operation->display) {
          if (space.id == operation->space) {
            position = count;
          }

          ++count;
        }
      }

      if (!children.value || CFGetTypeID(children.value) != CFArrayGetTypeID() ||
          CFArrayGetCount(static_cast<CFArrayRef>(children.value)) != static_cast<CFIndex>(count)) {
        return {};
      }

      const auto value = CFArrayGetValueAtIndex(static_cast<CFArrayRef>(children.value), position);

      if (!value || CFGetTypeID(value) != AXUIElementGetTypeID()) {
        return finish(false, "Mission Control returned an invalid Space control");
      }

      const auto target = static_cast<AXUIElementRef>(const_cast<void *>(value));

      if (AXUIElementPerformAction(target, CFSTR("AXRemoveDesktop")) != kAXErrorSuccess) {
        return finish(false, "macOS rejected removing the Space");
      }
    }

    acted = true;
    return {};
  }
};

MissionControl::MissionControl()
    : impl_(std::make_unique<Impl>()) {}

MissionControl::~MissionControl() {
  cancel();
}

void MissionControl::begin(SpaceOperation operation, const DesktopState &state) {
  cancel();
  impl_->operation = operation;
  impl_->deadline = Clock::now() + operation_timeout;

  for (const auto &space : state.spaces) {
    if (space.display == operation.display) {
      impl_->previous_spaces.insert(space.id);
    }

    if (space.id == operation.space) {
      impl_->target_uuid = space.uuid;
    }
  }
}

std::optional<SpaceCompletion> MissionControl::advance(const DesktopState &state) {
  return impl_->advance(state);
}

std::optional<SpaceOperation> MissionControl::pending() const {
  return impl_->operation;
}

bool MissionControl::readyForActivation() const {
  return !impl_->opened && Clock::now() - impl_->last_closed >= control_settle_time;
}

void MissionControl::cancel() {
  impl_->cancel();
}
