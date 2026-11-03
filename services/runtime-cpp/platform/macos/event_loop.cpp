#include "../event_loop.hpp"
#include "telar_platform/error.hpp"
#include <csignal>

namespace telar::runtime {

Kqueue::Kqueue()
    : queue_(::kqueue()) {
  if (!queue_) {
    throw SystemError{"create runtime event queue"};
  }

  setCloseOnExec(queue_.get());
}

void Kqueue::change(const struct kevent &event) {
  if (::kevent(queue_.get(), &event, 1, nullptr, 0, nullptr) != 0) {
    throw SystemError{"register runtime event"};
  }
}

void Kqueue::watch(int descriptor, std::uint64_t token) {
  readInterest(descriptor, token, true);
}

void Kqueue::readInterest(int descriptor, std::uint64_t token, bool enabled) {
  struct kevent event{};
  EV_SET(&event, descriptor, EVFILT_READ, EV_ADD | (enabled ? EV_ENABLE : EV_DISABLE), 0, 0, reinterpret_cast<void *>(token));
  change(event);
}

void Kqueue::writeInterest(int descriptor, std::uint64_t token, bool enabled) {
  struct kevent event{};
  EV_SET(&event, descriptor, EVFILT_WRITE, EV_ADD | (enabled ? EV_ENABLE : EV_DISABLE), 0, 0, reinterpret_cast<void *>(token));
  change(event);
}

void Kqueue::remove(int descriptor) noexcept {
  struct kevent events[2]{};
  EV_SET(&events[0], descriptor, EVFILT_READ, EV_DELETE, 0, 0, nullptr);
  EV_SET(&events[1], descriptor, EVFILT_WRITE, EV_DELETE, 0, 0, nullptr);
  ::kevent(queue_.get(), events, 2, nullptr, 0, nullptr);
}

void Kqueue::watchSignal(int signal_number) {
  struct kevent event{};
  EV_SET(&event, signal_number, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, nullptr);
  change(event);
  // Ignoring SIGCHLD discards the wait status; the event loop must reap it.
  ::signal(signal_number, signal_number == SIGCHLD ? +[](int) {} : SIG_IGN);
}

std::span<const Event> Kqueue::wait(std::chrono::nanoseconds timeout) {
  timeout = std::max(timeout, std::chrono::nanoseconds::zero());
  const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(timeout);
  const timespec duration{.tv_sec = seconds.count(),
                          .tv_nsec = (timeout - seconds).count()};
  const int count = ::kevent(queue_.get(), nullptr, 0, kernel_events_.data(), static_cast<int>(kernel_events_.size()), &duration);

  if (count < 0) {
    if (errno == EINTR) {
      return {};
    }

    throw SystemError{"wait for runtime event"};
  }

  for (int index = 0; index < count; ++index) {
    const auto &source = kernel_events_[index];
    events_[index] = Event{
        .kind = source.filter == EVFILT_SIGNAL ? EventKind::signal : source.filter == EVFILT_WRITE ? EventKind::writable
                                                                                                   : EventKind::readable,
        .descriptor = static_cast<int>(source.ident),
        .token = reinterpret_cast<std::uintptr_t>(source.udata),
        .closed = (source.flags & (EV_EOF | EV_ERROR)) != 0,
    };
  }

  return std::span<const Event>{events_}.first(static_cast<std::size_t>(count));
}

}
