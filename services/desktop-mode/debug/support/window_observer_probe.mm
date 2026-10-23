#include "window_observer_probe.hpp"
#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <condition_variable>
#include <dlfcn.h>
#include <mutex>
#include <thread>
#include <time.h>
#include <utility>

namespace {
  using WindowIdentifier = AXError (*)(AXUIElementRef, CGWindowID *);
  using GetWindowBounds = CGError (*)(int, std::uint32_t, CGRect *);
  using MainConnection = int (*)();

  // The observer's run loop never needs to wake for this; it only keeps the loop running.
  constexpr CFTimeInterval keep_alive = 1e9;

  std::uint32_t idOf(AXUIElementRef element) {
    static const auto identifier =
        reinterpret_cast<WindowIdentifier>(dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"));
    CGWindowID id = 0;
    return identifier && identifier(element, &id) == kAXErrorSuccess ? id : 0;
  }
} // namespace

namespace window_observer_probe {
  struct Observer::Impl {
    double timeout;
    std::thread thread;
    CFRunLoopRef loop = nullptr;
    std::mutex mutex;
    std::condition_variable changed;
    bool running = false;
    std::vector<Event> events;
    // Owned by the observer's thread.
    std::vector<AXObserverRef> observers;
    // Accessibility elements are retained as keys, never copied.
    CFMutableDictionaryRef windows = CFDictionaryCreateMutable(nullptr,
                                                               0,
                                                               &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);

    ~Impl() {
      CFRelease(windows);
    }

    std::uint32_t known(AXUIElementRef window) const {
      const auto value = static_cast<CFNumberRef>(CFDictionaryGetValue(windows, window));
      std::uint32_t number = 0;
      if (value) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &number);
      }

      return number;
    }

    void record(Kind kind, pid_t pid, std::uint32_t window) {
      std::lock_guard lock(mutex);
      events.push_back({kind, pid, window, now()});
    }

    // A window's destroy notification arrives after it is gone, so its number is kept from
    // when the window was first seen.
    void follow(AXObserverRef observer, AXUIElementRef window) {
      const auto number = idOf(window);
      if (!number || known(window)) {
        return;
      }

      CFDictionarySetValue(windows, window, (__bridge CFNumberRef) @(number));
      for (CFStringRef name : {kAXUIElementDestroyedNotification,
                               kAXWindowMovedNotification,
                               kAXWindowResizedNotification}) {
        AXObserverAddNotification(observer, window, name, this);
      }
    }

    static void notified(AXObserverRef observer,
                         AXUIElementRef element,
                         CFStringRef notification,
                         void *context) {
      auto &self = *static_cast<Impl *>(context);
      pid_t pid = 0;
      AXUIElementGetPid(element, &pid);
      const auto remembered = self.known(element);
      const auto number = remembered ? remembered : idOf(element);

      if (CFEqual(notification, kAXWindowCreatedNotification)) {
        self.record(Kind::created, pid, number);
        self.follow(observer, element);
      } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        self.record(Kind::destroyed, pid, number);
        CFDictionaryRemoveValue(self.windows, element);
      } else if (CFEqual(notification, kAXWindowMovedNotification)) {
        self.record(Kind::moved, pid, number);
      } else if (CFEqual(notification, kAXWindowResizedNotification)) {
        self.record(Kind::resized, pid, number);
      } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        self.record(Kind::focused, pid, number);
      }
    }

    Attachment attachOne(pid_t pid) {
      const auto start = now();
      AXObserverRef observer = nullptr;
      bool answered = AXObserverCreate(pid, notified, &observer) == kAXErrorSuccess;
      if (answered) {
        AXUIElementRef application = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(application, static_cast<float>(timeout));
        for (CFStringRef name :
             {kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification}) {
          answered =
              AXObserverAddNotification(observer, application, name, this) == kAXErrorSuccess &&
              answered;
        }

        CFTypeRef list = nullptr;
        if (AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &list) ==
                kAXErrorSuccess &&
            list && CFGetTypeID(list) == CFArrayGetTypeID()) {
          for (CFIndex index = 0; index < CFArrayGetCount(static_cast<CFArrayRef>(list)); ++index) {
            follow(observer,
                   static_cast<AXUIElementRef>(const_cast<void *>(
                       CFArrayGetValueAtIndex(static_cast<CFArrayRef>(list), index))));
          }
        } else {
          answered = false;
        }

        if (list) {
          CFRelease(list);
        }

        CFRelease(application);
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
        observers.push_back(observer);
      }

      return {pid, static_cast<double>(now() - start) / 1e6, answered};
    }

    // Runs a block on the observer's thread and waits for it.
    void perform(void (^block)()) {
      std::unique_lock lock(mutex);
      bool done = false;
      auto *flag = &done;
      CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, ^{
        block();
        std::lock_guard inner(mutex);
        *flag = true;
        changed.notify_all();
      });
      CFRunLoopWakeUp(loop);
      changed.wait(lock, [&] {
        return done;
      });
    }
  };

  Observer::Observer(double timeout)
      : impl_(std::make_unique<Impl>()) {
    impl_->timeout = timeout;
    impl_->thread = std::thread([impl = impl_.get()] {
      @autoreleasepool {
        CFRunLoopTimerRef timer =
            CFRunLoopTimerCreateWithHandler(nullptr,
                                            CFAbsoluteTimeGetCurrent() + keep_alive,
                                            0,
                                            0,
                                            0,
                                            ^(CFRunLoopTimerRef){
                                            });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        {
          std::lock_guard lock(impl->mutex);
          impl->loop = CFRunLoopGetCurrent();
          impl->running = true;
          impl->changed.notify_all();
        }

        CFRunLoopRun();
        CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        CFRelease(timer);
      }
    });

    std::unique_lock lock(impl_->mutex);
    impl_->changed.wait(lock, [&] {
      return impl_->running;
    });
  }

  Observer::~Observer() {
    auto *impl = impl_.get();
    impl->perform(^{
      for (auto observer : impl->observers) {
        CFRunLoopRemoveSource(impl->loop,
                              AXObserverGetRunLoopSource(observer),
                              kCFRunLoopDefaultMode);
        CFRelease(observer);
      }

      impl->observers.clear();
    });
    CFRunLoopStop(impl->loop);
    CFRunLoopWakeUp(impl->loop);
    impl->thread.join();
  }

  std::vector<Attachment> Observer::attach(const std::vector<std::int64_t> &pids) {
    __block std::vector<Attachment> result;
    auto *impl = impl_.get();
    const auto *list = &pids;
    impl->perform(^{
      for (const auto pid : *list) {
        result.push_back(impl->attachOne(static_cast<pid_t>(pid)));
      }
    });

    return result;
  }

  std::vector<Event> Observer::take() {
    std::lock_guard lock(impl_->mutex);
    return std::exchange(impl_->events, {});
  }

  std::vector<std::int64_t> regularApplications() {
    std::vector<std::int64_t> result;
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
      if (application.activationPolicy == NSApplicationActivationPolicyRegular &&
          application.processIdentifier != getpid()) {
        result.push_back(application.processIdentifier);
      }
    }

    return result;
  }

  std::uint64_t now() {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
  }

  QRectF serverBounds(std::uint32_t window) {
    static void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                                  RTLD_NOW | RTLD_LOCAL);
    static const auto connection =
        library ? reinterpret_cast<MainConnection>(dlsym(library, "SLSMainConnectionID")) : nullptr;
    static const auto bounds =
        library ? reinterpret_cast<GetWindowBounds>(dlsym(library, "SLSGetWindowBounds")) : nullptr;
    CGRect rect{};
    if (!connection || !bounds || bounds(connection(), window, &rect) != kCGErrorSuccess) {
      return {};
    }

    return {rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
  }
} // namespace window_observer_probe
