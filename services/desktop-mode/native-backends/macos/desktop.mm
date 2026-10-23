#include "../desktop.hpp"
#include "spaces_bridge.hpp"
#include "spaces_observer.hpp"
#include "virtual_spaces.hpp"
#include "../../trace.hpp"
#import <AppKit/AppKit.h>
#include <QTimer>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <utility>

namespace {
  using namespace std::chrono_literals;
  // How soon a publication the event queue refused is tried again.
  constexpr auto retry_interval = 20ms;
} // namespace

struct NativeDesktop::Impl {
  // A Space creation or removal, which waits on WindowManager and runs on the observer's thread.
  // The task writes the outcome before raising `done`; the UI thread reads it after seeing it.
  struct Outcome {
    std::atomic<bool> done = false;
    std::uint64_t space = 0;
    std::string error;
  };

  struct Pending {
    SpaceOperation operation;
    std::shared_ptr<Outcome> outcome = std::make_shared<Outcome>();
  };

  Sink publish;
  // Retries a publication the event queue refused.
  QTimer timer;
  NSMutableArray *observers = [NSMutableArray array];
  // The latest snapshot of macOS's own Spaces, which Telar's Spaces are laid over.
  DesktopState observed;
  DesktopState previous;
  std::optional<Pending> pending;
  std::optional<SpaceCompletion> completion;
  std::string error;
  bool observing = false;
  // Declared after the timer it delivers through, so it stops before the timer goes.
  macos::spaces::Observer observer{timer, [this](DesktopState state, std::string failure) {
                                     observe(std::move(state), std::move(failure));
                                   }};

  Impl() {
    timer.setSingleShot(true);
    // The observer delivers only changes while nothing is pending, so the retry publishes the
    // latest snapshot itself.
    QObject::connect(&timer, &QTimer::timeout, &timer, [this] {
      publishState(observed);
    });
  }

  // stop removes the notification observers before the observer can go away.
  void watch(NSNotificationCenter *center, NSNotificationName name) {
    auto *spaces = &observer;
    id notification = [center addObserverForName:name
                                          object:nil
                                           queue:NSOperationQueue.mainQueue
                                      usingBlock:^(NSNotification *) {
                                        spaces->wake();
                                      }];
    [observers addObject:notification];
  }

  void advanceOperation() {
    if (!pending || !pending->outcome->done.load(std::memory_order_acquire)) {
      return;
    }

    auto operation = pending->operation;
    const auto &outcome = *pending->outcome;
    if (operation.kind == SpaceOperation::Kind::create) {
      operation.space = outcome.space;
    }

    completion = SpaceCompletion{operation, outcome.error.empty(), outcome.error};
    error = outcome.error;
    pending.reset();
  }

  void publishState(DesktopState state) {
    TELAR_TRACE("native.desktop.publish_state");
    macos::spaces::VirtualSpaces::get().overlay(state);
    state.pending_operation = pending ? std::optional{pending->operation} : std::nullopt;
    state.completed_operation = completion;
    state.error = error;

    if (state != previous) {
      if (publish(state)) {
        previous = std::move(state);
      } else {
        timer.start(retry_interval);
      }
    }

    // A pending operation is confirmed from a snapshot every frame.
    observer.setUrgent(pending.has_value());
  }

  // Acts on a snapshot, taken by the observer off this thread: completes what is pending, then
  // publishes.
  void observe(DesktopState state, std::string failure) {
    TELAR_TRACE("native.desktop.observe");
    if (!publish || observing) {
      return;
    }

    observing = true;
    if (failure.empty()) {
      observed = std::move(state);
    } else {
      error = failure;
    }

    advanceOperation();
    publishState(observed);
    observing = false;
  }

  // Publishes what a command changed at once; the observer confirms the rest.
  void announce() {
    publishState(observed);
    observer.wake();
  }

  void stop() {
    publish = {};
    timer.stop();
    observer.stop();

    for (id observer in observers) {
      [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
      [NSNotificationCenter.defaultCenter removeObserver:observer];
    }

    [observers removeAllObjects];

    // Other applications' windows must not stay in layers nobody shows.
    try {
      macos::spaces::VirtualSpaces::get().release();
    } catch (const std::exception &exception) {
      std::fprintf(stderr, "Releasing Telar's Spaces failed: %s\n", exception.what());
    }

    pending.reset();
    completion.reset();
    observed = {};
    previous = {};
    error.clear();
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
  impl_->watch(NSNotificationCenter.defaultCenter,
               NSApplicationDidChangeScreenParametersNotification);

  // The first snapshot is taken here, on the UI thread, so the desktop has a state before
  // anything asks for one, and SkyLight is set up before another thread uses it.
  DesktopState state;
  std::string failure;
  try {
    state = macos::spaces::snapshot();
  } catch (const std::exception &exception) {
    failure = exception.what();
  }

  impl_->observe(std::move(state), std::move(failure));
  impl_->observer.post([] {
    macos::spaces::VirtualSpaces::get().prepare();
  });
  impl_->observer.start();
}

void NativeDesktop::stop() {
  impl_->stop();
}

void NativeDesktop::activate(std::uint64_t space) {
  TELAR_TRACE("native.desktop.activate");
  auto &spaces = macos::spaces::VirtualSpaces::get();
  impl_->error.clear();

  try {
    spaces.show(space);
    const auto display = spaces.display(space);
    const auto focused =
        std::ranges::find(impl_->previous.spaces, impl_->previous.focused_space, &DesktopSpace::id);
    const auto target = std::ranges::find(impl_->observed.displays, display, &DesktopDisplay::id);

    // Focusing a display can wait on another application through Accessibility.
    if (target != impl_->observed.displays.end() &&
        (focused == impl_->previous.spaces.end() || focused->display != display)) {
      impl_->observer.post([target = *target] {
        macos::spaces::focusDisplay(target);
      });
    }
  } catch (const std::exception &exception) {
    impl_->error = exception.what();
  }

  impl_->announce();
}

void NativeDesktop::changeSpace(SpaceOperation operation) {
  TELAR_TRACE("native.desktop.change_space");
  if (impl_->pending) {
    impl_->completion = SpaceCompletion{operation, false, "Another Space operation is in progress"};
    impl_->error = impl_->completion->error;
    impl_->announce();
    return;
  }

  impl_->error.clear();
  impl_->completion.reset();
  const auto &state = impl_->previous;

  try {
    if (!state.available) {
      throw std::runtime_error("The macOS desktop is unavailable");
    }

    if (operation.kind == SpaceOperation::Kind::remove) {
      const auto target = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);
      if (target == state.spaces.end() || target->fullscreen) {
        throw std::runtime_error("Only an existing Telar Space can be removed");
      }

      operation.display = target->display;
      const auto remaining = std::ranges::count_if(state.spaces, [&](const auto &space) {
        return space.display == target->display && !space.fullscreen;
      });

      if (remaining <= 1) {
        throw std::runtime_error("The last Space of a display cannot be removed");
      }
    }

    if (std::ranges::find(state.displays, operation.display, &DesktopDisplay::id) ==
        state.displays.end()) {
      throw std::runtime_error("The target display is unavailable");
    }

    impl_->pending = Impl::Pending{operation};
    impl_->observer.post([operation, outcome = impl_->pending->outcome] {
      try {
        if (operation.kind == SpaceOperation::Kind::create) {
          outcome->space = macos::spaces::VirtualSpaces::get().create(operation.display);
        } else {
          macos::spaces::VirtualSpaces::get().remove(operation.space);
        }
      } catch (const std::exception &exception) {
        outcome->error = exception.what();
      }

      outcome->done.store(true, std::memory_order_release);
    });
  } catch (const std::exception &exception) {
    impl_->completion = SpaceCompletion{operation, false, exception.what()};
    impl_->error = exception.what();
  }

  impl_->announce();
}
