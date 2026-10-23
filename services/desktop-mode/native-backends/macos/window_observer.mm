#include "../../ui/workbench/native.hpp"
#include "spaces_bridge.hpp"
#include "virtual_spaces.hpp"
#include "../../trace.hpp"
#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <QMetaObject>
#include <QObject>
#include <condition_variable>
#include <dlfcn.h>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <unistd.h>
#include <utility>

namespace workbench::native {
  namespace {
    using WindowIdentifier = AXError (*)(AXUIElementRef, CGWindowID *);

    // Each Accessibility call waits at most this long for an application that does not answer.
    constexpr float accessibility_timeout = 0.05f;
    // A window larger than the size written to it by more than this kept a size of its own.
    constexpr double size_tolerance = 1;
    // How long after refusing a size a window is read again, so a size the application had not
    // laid out yet is not taken for one it keeps.
    constexpr std::int64_t refusal_settle_ns = 150 * NSEC_PER_MSEC;
    // An application gets its Dock icon after macOS announces its launch, and a notification can
    // be missed: this often the observer attaches to new applications and reads again anyway.
    constexpr CFTimeInterval rescan_interval = 2;

    std::uint32_t idOf(AXUIElementRef element) {
      static const auto identifier =
          reinterpret_cast<WindowIdentifier>(dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"));
      CGWindowID id = 0;
      return identifier && identifier(element, &id) == kAXErrorSuccess ? id : 0;
    }

    QString text(CFTypeRef value) {
      return value && CFGetTypeID(value) == CFStringGetTypeID()
                 ? QString::fromNSString((__bridge NSString *)value)
                 : QString();
    }

    QString attribute(AXUIElementRef element, CFStringRef name) {
      CFTypeRef value = nullptr;
      AXUIElementCopyAttributeValue(element, name, &value);
      const auto result = text(value);
      if (value) {
        CFRelease(value);
      }

      return result;
    }

    bool flag(AXUIElementRef element, CFStringRef name) {
      CFTypeRef value = nullptr;
      AXUIElementCopyAttributeValue(element, name, &value);
      const bool result = value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                          CFBooleanGetValue(static_cast<CFBooleanRef>(value));
      if (value) {
        CFRelease(value);
      }

      return result;
    }

    // A window Accessibility has told the observer about, with what only Accessibility knows.
    struct Known {
      AXUIElementRef element = nullptr;
      std::int64_t pid = 0;
      QString title;
      bool floating = false;
      bool minimized = false;
    };

    // The latest write a window is waiting for. Writes replace each other: only the last runs.
    struct Write {
      std::optional<QRectF> frame;
      std::optional<QPointF> position;
      bool focus = false;
      bool close = false;
    };

    // What the per-application queues share with the observer, outliving it while a queued
    // write still runs.
    struct Writes {
      std::mutex mutex;
      std::map<std::uint32_t, Write> pending;
      // The smallest size each window's application keeps, learned from sizes it refused; a
      // dimension it never refused stays 0.
      std::map<std::uint32_t, QSizeF> minimums;
      // Asks the observer for a read; cleared before the observer goes away.
      std::function<void()> wake;
    };

    std::optional<QSizeF> sizeOf(AXUIElementRef window) {
      CFTypeRef value = nullptr;
      CGSize size{};
      const bool read = AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &value) ==
                            kAXErrorSuccess &&
                        value && CFGetTypeID(value) == AXValueGetTypeID() &&
                        AXValueGetValue(static_cast<AXValueRef>(value), kAXValueTypeCGSize, &size);
      if (value) {
        CFRelease(value);
      }

      return read ? std::optional{QSizeF(size.width, size.height)} : std::nullopt;
    }

    // The dimensions of `kept` that exceed what was written, 0 for the others.
    QSizeF exceeding(QSizeF kept, QSizeF written) {
      return {kept.width() > written.width() + size_tolerance ? kept.width() : 0,
              kept.height() > written.height() + size_tolerance ? kept.height() : 0};
    }

    // Returns the size the window kept when its application accepted the call but not the size,
    // as some do below their minimum.
    std::optional<QSizeF> apply(AXUIElementRef window, std::int64_t pid, const Write &write) {
      std::optional<QSizeF> kept;
      if (write.frame) {
        CGSize size{write.frame->width(), write.frame->height()};
        CGPoint origin{write.frame->x(), write.frame->y()};
        const auto dimensions = AXValueCreate(kAXValueTypeCGSize, &size);
        const auto position = AXValueCreate(kAXValueTypeCGPoint, &origin);
        // AppKit cuts a new size down to what fits on screen from where the window is, so a window
        // growing from the right would keep its width: it moves first, then grows, then moves
        // again in case the new size shifted it.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
        const bool sized =
            AXUIElementSetAttributeValue(window, kAXSizeAttribute, dimensions) == kAXErrorSuccess;
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
        CFRelease(dimensions);
        CFRelease(position);

        const auto actual = sized ? sizeOf(window) : std::nullopt;
        if (actual && !exceeding(*actual, write.frame->size()).isNull()) {
          kept = actual;
        }
      } else if (write.position) {
        CGPoint origin{write.position->x(), write.position->y()};
        const auto position = AXValueCreate(kAXValueTypeCGPoint, &origin);
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, position);
        CFRelease(position);
      }

      if (write.close) {
        CFTypeRef button = nullptr;
        AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute, &button);
        if (button && CFGetTypeID(button) == AXUIElementGetTypeID()) {
          AXUIElementPerformAction(static_cast<AXUIElementRef>(button), kAXPressAction);
        }

        if (button) {
          CFRelease(button);
        }

        return kept;
      }

      if (write.focus) {
        [[NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(pid)]
            activateWithOptions:0];
        AXUIElementPerformAction(window, kAXRaiseAction);
        AXUIElementSetAttributeValue(window, kAXMainAttribute, kCFBooleanTrue);
      }

      return kept;
    }
  } // namespace

  struct WindowObserver::Impl {
    QObject &receiver;
    Delivery deliver;
    std::thread thread;
    CFRunLoopRef loop = nullptr;
    std::mutex mutex;
    std::condition_variable started;
    // Shared with the UI thread, which reads it to address writes; guarded by mutex.
    std::map<std::uint32_t, Known> known;
    std::map<std::int64_t, dispatch_queue_t> queues;
    std::shared_ptr<Writes> writes = std::make_shared<Writes>();
    // The observer's thread only.
    std::map<std::int64_t, AXObserverRef> observers;
    std::map<std::int64_t, QString> applications;
    std::uint32_t focused = 0;
    ForeignWindows delivered;
    bool delivered_once = false;
    bool scheduled = false;
    NSMutableArray *notifications = [NSMutableArray array];

    Impl(QObject &owner, Delivery delivery)
        : receiver(owner),
          deliver(std::move(delivery)) {}

    // Runs on the observer's thread at its next turn.
    void post(void (^block)()) {
      CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, block);
      CFRunLoopWakeUp(loop);
    }

    // Notifications come in bursts; one read of the window server answers them all.
    void schedule() {
      if (scheduled) {
        return;
      }

      scheduled = true;
      post(^{
        scheduled = false;
        read();
      });
    }

    static void
    notified(AXObserverRef, AXUIElementRef element, CFStringRef notification, void *context) {
      auto &self = *static_cast<Impl *>(context);
      pid_t pid = 0;
      AXUIElementGetPid(element, &pid);

      if (CFEqual(notification, kAXWindowCreatedNotification)) {
        self.learn(element, pid);
      } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        self.forget(element);
      } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        self.focusedChanged(pid, element);
      } else if (CFEqual(notification, kAXTitleChangedNotification)) {
        self.update(element, [&](Known &window) {
          window.title = attribute(element, kAXTitleAttribute);
        });
      } else if (CFEqual(notification, kAXWindowMiniaturizedNotification) ||
                 CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        const bool minimized = CFEqual(notification, kAXWindowMiniaturizedNotification);
        self.update(element, [&](Known &window) {
          window.minimized = minimized;
        });
      }

      self.schedule();
    }

    template <typename Change> void update(AXUIElementRef element, Change change) {
      std::lock_guard lock(mutex);
      for (auto &[id, window] : known) {
        if (CFEqual(window.element, element)) {
          change(window);
          return;
        }
      }
    }

    // Standard windows and dialogs are managed; menus, popovers and the like are not windows to
    // place. A window that cannot be resized floats.
    void learn(AXUIElementRef element, pid_t pid) {
      const auto id = idOf(element);
      const auto subrole = attribute(element, kAXSubroleAttribute);
      const bool standard = subrole == QString::fromCFString(kAXStandardWindowSubrole);
      const bool dialog = subrole == QString::fromCFString(kAXDialogSubrole) ||
                          subrole == QString::fromCFString(kAXSystemDialogSubrole);
      {
        std::lock_guard lock(mutex);
        if (!id || known.contains(id) || (!standard && !dialog)) {
          return;
        }
      }

      Boolean resizable = false;
      AXUIElementIsAttributeSettable(element, kAXSizeAttribute, &resizable);
      Known window{
          .element = static_cast<AXUIElementRef>(CFRetain(element)),
          .pid = pid,
          .title = attribute(element, kAXTitleAttribute),
          .floating = !standard || !resizable,
          .minimized = flag(element, kAXMinimizedAttribute),
      };
      AXUIElementSetMessagingTimeout(window.element, accessibility_timeout);

      if (const auto observer = observers.find(pid); observer != observers.end()) {
        for (CFStringRef name : {kAXUIElementDestroyedNotification,
                                 kAXWindowMovedNotification,
                                 kAXWindowResizedNotification,
                                 kAXTitleChangedNotification,
                                 kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification}) {
          AXObserverAddNotification(observer->second, element, name, this);
        }
      }

      std::lock_guard lock(mutex);
      known.emplace(id, window);
    }

    void forget(AXUIElementRef element) {
      std::lock_guard lock(mutex);
      for (auto it = known.begin(); it != known.end(); ++it) {
        if (CFEqual(it->second.element, element)) {
          CFRelease(it->second.element);
          known.erase(it);
          return;
        }
      }
    }

    void focusedChanged(pid_t pid, AXUIElementRef window) {
      if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == pid) {
        focused = idOf(window);
      }
    }

    void attach(NSRunningApplication *application) {
      const auto pid = application.processIdentifier;
      if (application.activationPolicy != NSApplicationActivationPolicyRegular || pid == getpid() ||
          observers.contains(pid)) {
        return;
      }

      TELAR_TRACE("native.windows.attach");
      AXObserverRef observer = nullptr;
      if (AXObserverCreate(pid, notified, &observer) != kAXErrorSuccess) {
        return;
      }

      observers.emplace(pid, observer);
      applications.emplace(pid,
                            QString::fromNSString(application.bundleIdentifier
                                                      ?: application.localizedName ?: @""));
      AXUIElementRef element = AXUIElementCreateApplication(pid);
      AXUIElementSetMessagingTimeout(element, accessibility_timeout);
      for (CFStringRef name : {kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification}) {
        AXObserverAddNotification(observer, element, name, this);
      }

      CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
      CFTypeRef windows = nullptr;
      if (AXUIElementCopyAttributeValue(element, kAXWindowsAttribute, &windows) ==
              kAXErrorSuccess &&
          windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
        const auto list = static_cast<CFArrayRef>(windows);
        for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
          learn(
              static_cast<AXUIElementRef>(const_cast<void *>(CFArrayGetValueAtIndex(list, index))),
              pid);
        }
      }

      if (windows) {
        CFRelease(windows);
      }

      if (application.active) {
        CFTypeRef window = nullptr;
        AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute, &window);
        if (window && CFGetTypeID(window) == AXUIElementGetTypeID()) {
          focused = idOf(static_cast<AXUIElementRef>(window));
        }

        if (window) {
          CFRelease(window);
        }
      }

      CFRelease(element);
    }

    void detach(pid_t pid) {
      if (const auto observer = observers.find(pid); observer != observers.end()) {
        CFRunLoopRemoveSource(loop,
                              AXObserverGetRunLoopSource(observer->second),
                              kCFRunLoopDefaultMode);
        CFRelease(observer->second);
        observers.erase(observer);
      }

      applications.erase(pid);
      std::lock_guard lock(mutex);
      std::erase_if(known, [&](auto &entry) {
        if (entry.second.pid != pid) {
          return false;
        }

        CFRelease(entry.second.element);
        return true;
      });
      queues.erase(pid);
    }

    // The window server's list is the truth for what exists and where: a window Accessibility
    // knew but the list no longer has is gone, whether or not its notification arrived.
    void read() {
      TELAR_TRACE("native.windows.read");
      NSArray *list = CFBridgingRelease(
          CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
                                     kCGNullWindowID));
      std::map<std::uint32_t, CGRect> bounds;
      for (NSDictionary *entry in list) {
        CGRect frame{};
        if ([entry[(__bridge NSString *)kCGWindowLayer] intValue] == 0 &&
            CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)entry[(__bridge NSString *)kCGWindowBounds],
                &frame)) {
          bounds.emplace([entry[(__bridge NSString *)kCGWindowNumber] unsignedIntValue], frame);
        }
      }

      // An application hidden with Cmd+H keeps its windows listed, out of sight like minimized
      // ones.
      std::map<std::int64_t, bool> hidden;
      for (const auto &[pid, name] : applications) {
        hidden[pid] =
            [NSRunningApplication runningApplicationWithProcessIdentifier:static_cast<pid_t>(pid)]
                .hidden;
      }

      ForeignWindows next{.focused = 0};
      {
        std::lock_guard lock(mutex);
        std::erase_if(known, [&](auto &entry) {
          if (bounds.contains(entry.first)) {
            return false;
          }

          CFRelease(entry.second.element);
          return true;
        });

        for (const auto &[id, window] : known) {
          if (window.minimized || hidden[window.pid]) {
            continue;
          }

          const auto &frame = bounds.at(id);
          next.windows.push_back({
              .id = id,
              .pid = window.pid,
              .application =
                  applications.contains(window.pid) ? applications.at(window.pid) : QString(),
              .title = window.title,
              .frame = QRectF(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height),
              .floating = window.floating,
          });
        }
      }

      {
        std::lock_guard lock(writes->mutex);
        std::erase_if(writes->minimums, [&](const auto &entry) {
          return !bounds.contains(entry.first);
        });

        for (auto &window : next.windows) {
          if (const auto found = writes->minimums.find(window.id);
              found != writes->minimums.end()) {
            window.minimum = found->second;
          }
        }
      }

      const auto &spaces = macos::spaces::VirtualSpaces::get();
      for (auto &window : next.windows) {
        const auto center = window.frame.center();
        const auto space = macos::spaces::spaceOf(window.id);
        window.backstage = spaces.offstage(space);
        window.space = spaces.resolve(space, CGPointMake(center.x(), center.y()));
        if (window.id == focused) {
          next.focused = focused;
        }
      }

      if (delivered_once && next == delivered) {
        return;
      }

      delivered = next;
      delivered_once = true;
      QMetaObject::invokeMethod(
          &receiver,
          [deliver = deliver, windows = std::move(next)]() mutable {
            deliver(std::move(windows));
          },
          Qt::QueuedConnection);
    }

    void watchWorkspace() {
      auto *center = NSWorkspace.sharedWorkspace.notificationCenter;
      const auto on = ^(NSNotificationName name, void (^handle)(NSRunningApplication *)) {
        id token = [center addObserverForName:name
                                       object:nil
                                        queue:nil
                                   usingBlock:^(NSNotification *notification) {
                                     NSRunningApplication *application =
                                         notification.userInfo[NSWorkspaceApplicationKey];
                                     post(^{
                                       handle(application);
                                       schedule();
                                     });
                                   }];
        [notifications addObject:token];
      };

      on(NSWorkspaceDidLaunchApplicationNotification, ^(NSRunningApplication *application) {
        attach(application);
      });
      on(NSWorkspaceDidTerminateApplicationNotification, ^(NSRunningApplication *application) {
        detach(application.processIdentifier);
      });
      on(NSWorkspaceDidHideApplicationNotification,
         ^(NSRunningApplication *){
         });
      on(NSWorkspaceDidUnhideApplicationNotification,
         ^(NSRunningApplication *){
         });
      on(NSWorkspaceDidActivateApplicationNotification, ^(NSRunningApplication *application) {
        attach(application);
        AXUIElementRef element = AXUIElementCreateApplication(application.processIdentifier);
        AXUIElementSetMessagingTimeout(element, accessibility_timeout);
        CFTypeRef window = nullptr;
        AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute, &window);
        focused = window && CFGetTypeID(window) == AXUIElementGetTypeID()
                      ? idOf(static_cast<AXUIElementRef>(window))
                      : 0;
        if (window) {
          CFRelease(window);
        }

        CFRelease(element);
      });
    }

    void rescan() {
      @autoreleasepool {
        for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
          attach(application);
        }

        read();
      }
    }

    void run() {
      @autoreleasepool {
        CFRunLoopTimerRef timer =
            CFRunLoopTimerCreateWithHandler(nullptr,
                                            CFAbsoluteTimeGetCurrent() + rescan_interval,
                                            rescan_interval,
                                            0,
                                            0,
                                            ^(CFRunLoopTimerRef) {
                                              rescan();
                                            });
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        {
          std::lock_guard lock(mutex);
          loop = CFRunLoopGetCurrent();
          started.notify_all();
        }

        {
          std::lock_guard lock(writes->mutex);
          writes->wake = [this] {
            post(^{
              schedule();
            });
          };
        }

        watchWorkspace();
        rescan();
        CFRunLoopRun();

        for (id token in notifications) {
          [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:token];
        }

        for (const auto &[pid, observer] : observers) {
          CFRelease(observer);
        }

        observers.clear();
        CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
        CFRelease(timer);
      }
    }

    // Queues a write for the window's application; a write already waiting for the same window
    // takes this one's place instead.
    void write(std::uint32_t window, void (^change)(Write &)) {
      std::lock_guard lock(mutex);
      const auto found = known.find(window);
      if (found == known.end()) {
        return;
      }

      auto &queue = queues[found->second.pid];
      if (!queue) {
        queue = dispatch_queue_create("telar.windows.application", DISPATCH_QUEUE_SERIAL);
      }

      auto shared = writes;
      bool waiting = false;
      {
        std::lock_guard inner(shared->mutex);
        waiting = shared->pending.contains(window);
        change(shared->pending[window]);
      }

      if (waiting) {
        return;
      }

      const auto element = static_cast<AXUIElementRef>(CFRetain(found->second.element));
      const auto pid = found->second.pid;
      const auto target = queue;
      dispatch_async(queue, ^{
        Write latest;
        {
          std::lock_guard inner(shared->mutex);
          latest = shared->pending.at(window);
          shared->pending.erase(window);
        }

        const auto kept = apply(element, pid, latest);
        if (!kept) {
          CFRelease(element);
          return;
        }

        // The size counts once it holds and no newer write has changed what was asked.
        const auto written = latest.frame->size();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, refusal_settle_ns), target, ^{
          const auto again = sizeOf(element);
          CFRelease(element);
          std::lock_guard inner(shared->mutex);
          if (!again || *again != *kept || shared->pending.contains(window)) {
            return;
          }

          auto &minimum = shared->minimums.try_emplace(window, 0, 0).first->second;
          minimum = minimum.expandedTo(exceeding(*kept, written));
          if (shared->wake) {
            shared->wake();
          }
        });
      });
    }
  };

  WindowObserver::WindowObserver(QObject &receiver, Delivery deliver)
      : impl_(std::make_unique<Impl>(receiver, std::move(deliver))) {
    if (!AXIsProcessTrusted()) {
      return;
    }

    impl_->thread = std::thread([impl = impl_.get()] {
      impl->run();
    });

    std::unique_lock lock(impl_->mutex);
    impl_->started.wait(lock, [&] {
      return impl_->loop != nullptr;
    });
  }

  WindowObserver::~WindowObserver() {
    if (!impl_->thread.joinable()) {
      return;
    }

    {
      std::lock_guard lock(impl_->writes->mutex);
      impl_->writes->wake = {};
    }

    CFRunLoopStop(impl_->loop);
    CFRunLoopWakeUp(impl_->loop);
    impl_->thread.join();
    for (auto &[id, window] : impl_->known) {
      CFRelease(window.element);
    }
  }

  void WindowObserver::place(std::uint32_t window, std::uint64_t space, QRectF frame) {
    TELAR_TRACE("native.windows.place");
    const std::uint32_t windows[] = {window};
    macos::spaces::moveToLayer(windows, macos::spaces::VirtualSpaces::get().stage(space));
    impl_->write(window, ^(Write &write) {
      write.frame = frame;
      write.position.reset();
    });
  }

  void WindowObserver::move(std::uint32_t window, QPointF position) {
    TELAR_TRACE("native.windows.move");
    impl_->write(window, ^(Write &write) {
      write.position = position;
      write.frame.reset();
    });
  }

  // The window waits on its Space's shelf, a layer that is never shown, which needs nothing from
  // its application.
  void WindowObserver::hide(std::uint32_t window, std::uint64_t space) {
    TELAR_TRACE("native.windows.hide");
    const std::uint32_t windows[] = {window};
    macos::spaces::moveToLayer(windows, macos::spaces::VirtualSpaces::get().shelf(space));
  }

  void WindowObserver::sendToBackstage(std::uint32_t window) {
    TELAR_TRACE("native.windows.send_to_backstage");
    const std::uint32_t windows[] = {window};
    macos::spaces::VirtualSpaces::get().sendToBackstage(windows);
  }

  void WindowObserver::takeOver(std::uint32_t window, std::uint32_t display, QRectF area) {
    TELAR_TRACE("native.windows.take_over");
    const std::uint32_t windows[] = {window};
    macos::spaces::VirtualSpaces::get().takeOver(display, windows);
    impl_->write(window, ^(Write &write) {
      write.frame = area;
      write.position.reset();
      write.focus = true;
    });
  }

  void WindowObserver::endTakeover(std::uint32_t display) {
    TELAR_TRACE("native.windows.end_takeover");
    macos::spaces::VirtualSpaces::get().endTakeover(display);
  }

  void WindowObserver::focus(std::uint32_t window) {
    TELAR_TRACE("native.windows.focus");
    impl_->write(window, ^(Write &write) {
      write.focus = true;
    });
  }

  void WindowObserver::close(std::uint32_t window) {
    TELAR_TRACE("native.windows.close");
    impl_->write(window, ^(Write &write) {
      write.close = true;
    });
  }
} // namespace workbench::native
