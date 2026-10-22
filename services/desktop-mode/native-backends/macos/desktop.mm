#include "../desktop.hpp"
#include "spaces_bridge.hpp"
#include "spaces_observer.hpp"
#include "../../trace.hpp"
#import <AppKit/AppKit.h>
#include <QTimer>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <utility>

namespace {
  using Clock = std::chrono::steady_clock;
  using namespace std::chrono_literals;
  constexpr auto operation_timeout = 5s;
  // How soon a publication the event queue refused is tried again.
  constexpr auto retry_interval = 20ms;
} // namespace

struct NativeDesktop::Impl {
  struct Pending {
    SpaceOperation operation;
    Clock::time_point deadline = Clock::now() + operation_timeout;
    bool relocating = false;
    bool rolling_back = false;
    std::string failure;
  };

  Sink publish;
  // Retries a publication the event queue refused.
  QTimer timer;
  NSMutableArray *observers = [NSMutableArray array];
  // The latest snapshot, which commands check themselves against instead of taking one.
  DesktopState observed;
  DesktopState previous;
  std::optional<Pending> pending;
  std::optional<SpaceCompletion> completion;
  std::uint64_t target = 0;
  Clock::time_point activation_deadline;
  bool display_focus_sent = false;
  bool observing = false;
  std::string error;
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

  void finish(bool succeeded, std::string message = {}) {
    completion = SpaceCompletion{pending->operation, succeeded, std::move(message)};
    error = completion->error;
    pending.reset();
  }

  // A created Space whose placement fails must not escape without an owner.
  void failOperation(const std::string &message) {
    if (pending->operation.kind != SpaceOperation::Kind::create || !pending->operation.space ||
        pending->rolling_back) {
      finish(false, message);
      return;
    }

    try {
      macos::spaces::remove(pending->operation.space);
      pending->rolling_back = true;
      pending->failure = message;
      pending->deadline = Clock::now() + operation_timeout;
    } catch (const std::exception &exception) {
      finish(false, message + "; could not remove the new Space: " + exception.what());
    }
  }

  void advanceOperation(const DesktopState &state) {
    if (!pending) {
      return;
    }

    const auto &operation = pending->operation;
    const auto found = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);

    if (pending->rolling_back) {
      if (found == state.spaces.end()) {
        finish(false, pending->failure);
      } else if (Clock::now() >= pending->deadline) {
        finish(false,
               pending->failure + "; cleanup timed out for Space " +
                   std::to_string(operation.space));
      }
      return;
    }

    if (operation.kind == SpaceOperation::Kind::remove && found == state.spaces.end()) {
      finish(true);
      return;
    }

    if (operation.kind == SpaceOperation::Kind::create && found != state.spaces.end()) {
      if (found->display == operation.display) {
        finish(true);
        return;
      }

      if (!pending->relocating) {
        const auto display =
            std::ranges::find(state.displays, operation.display, &DesktopDisplay::id);

        if (display == state.displays.end()) {
          throw std::runtime_error("The requested display disappeared during Space creation");
        }

        const auto count = static_cast<unsigned>(
            std::ranges::count(state.spaces, display->id, &DesktopSpace::display));
        macos::spaces::move(operation.space, *display, count);
        pending->relocating = true;
      }
    }

    if (Clock::now() >= pending->deadline) {
      throw std::runtime_error("macOS did not confirm the requested Space operation");
    }
  }

  void advanceActivation(const DesktopState &state) {
    if (!target) {
      return;
    }

    const auto space = std::ranges::find(state.spaces, target, &DesktopSpace::id);

    if (state.focused_space == target) {
      target = 0;
    } else if (space == state.spaces.end() || Clock::now() >= activation_deadline) {
      target = 0;
      error = space != state.spaces.end() && space->visible
                  ? "The Space is visible, but macOS did not focus its display"
                  : "macOS did not activate the requested Space";
    } else if (space->visible && !display_focus_sent) {
      const auto display = std::ranges::find(state.displays, space->display, &DesktopDisplay::id);

      if (display == state.displays.end()) {
        throw std::runtime_error("The target display is unavailable");
      }

      // Focusing a display can wait on another application through Accessibility.
      observer.post([display = *display] {
        macos::spaces::focusDisplay(display);
      });

      display_focus_sent = true;
    }
  }

  void publishState(DesktopState state) {
    TELAR_TRACE("native.desktop.publish_state");
    state.pending_space = target;
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

    // Something pending is confirmed, or times out, from a snapshot every frame.
    observer.setUrgent(target || pending);
  }

  // Acts on a snapshot, taken by the observer off this thread: confirms or times out what is
  // pending, then publishes.
  void observe(DesktopState state, std::string failure) {
    TELAR_TRACE("native.desktop.observe");
    if (!publish || observing) {
      return;
    }

    observing = true;
    try {
      if (!failure.empty()) {
        throw std::runtime_error(failure);
      }

      observed = state;
      advanceOperation(state);
      advanceActivation(state);
    } catch (const std::exception &exception) {
      error = exception.what();
      target = 0;

      if (pending) {
        failOperation(error);
      }
    }

    publishState(std::move(state));
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

    if (pending && pending->operation.kind == SpaceOperation::Kind::create &&
        pending->operation.space) {
      try {
        macos::spaces::remove(pending->operation.space);
      } catch (const std::exception &exception) {
        std::fprintf(stderr, "Space creation cleanup failed: %s\n", exception.what());
      }
    }

    pending.reset();
    completion.reset();
    target = 0;
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
  impl_->observer.start();
}

void NativeDesktop::stop() {
  impl_->stop();
}

void NativeDesktop::activate(std::uint64_t space) {
  TELAR_TRACE("native.desktop.activate");
  if (impl_->pending || impl_->target) {
    impl_->error = "Wait for the current Space operation to finish";
    impl_->announce();
    return;
  }

  impl_->error.clear();

  try {
    macos::spaces::activate(impl_->observed, space);
    impl_->target = space;
    impl_->display_focus_sent = false;
    impl_->activation_deadline = Clock::now() + operation_timeout;
  } catch (const std::exception &exception) {
    impl_->error = exception.what();
  }

  impl_->announce();
}

void NativeDesktop::changeSpace(SpaceOperation operation) {
  TELAR_TRACE("native.desktop.change_space");
  if (impl_->pending || impl_->target) {
    impl_->completion = SpaceCompletion{operation, false, "Another Space operation is in progress"};
    impl_->error = impl_->completion->error;
    impl_->announce();
    return;
  }

  impl_->error.clear();
  impl_->completion.reset();

  try {
    const auto &state = impl_->observed;

    if (!state.available) {
      throw std::runtime_error("The macOS Spaces catalog is unavailable");
    }

    if (operation.kind == SpaceOperation::Kind::remove) {
      const auto target = std::ranges::find(state.spaces, operation.space, &DesktopSpace::id);

      if (target == state.spaces.end() || target->fullscreen) {
        throw std::runtime_error("Only an existing ordinary Space can be removed");
      }

      operation.display = target->display;
      const auto ordinary = std::ranges::count_if(state.spaces, [&](const auto &space) {
        return space.display == target->display && !space.fullscreen;
      });

      if (ordinary <= 1) {
        throw std::runtime_error("macOS must keep at least one ordinary Space on each display");
      }
    }

    if (std::ranges::find(state.displays, operation.display, &DesktopDisplay::id) ==
        state.displays.end()) {
      throw std::runtime_error("The target display is unavailable");
    }

    if (operation.kind == SpaceOperation::Kind::create) {
      operation.space = 0;
    }

    impl_->pending = Impl::Pending{operation};

    if (operation.kind == SpaceOperation::Kind::create) {
      const auto created = macos::spaces::create();

      if (std::ranges::find(state.spaces, created, &DesktopSpace::id) != state.spaces.end()) {
        throw std::runtime_error("SkyLight returned an existing Space ID");
      }

      impl_->pending->operation.space = created;
    } else {
      macos::spaces::remove(operation.space);
    }

    impl_->announce();
  } catch (const std::exception &exception) {
    if (impl_->pending) {
      impl_->failOperation(exception.what());
    } else {
      impl_->completion = SpaceCompletion{operation, false, exception.what()};
      impl_->error = exception.what();
    }

    impl_->announce();
  }
}
