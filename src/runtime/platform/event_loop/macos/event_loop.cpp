module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.platform.event_loop;

import std;
import telar.sys.process;
import telar.sys.apple;
import telar.sys.posix;
import telar.tbc;

import telar.platform.error;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // A kevent with either flag reports its descriptor closed.
    constexpr auto closed_flags = static_cast<std::uint16_t>(combineFlags(EV_EOF, EV_ERROR));

    // The kevent flags that add a filter, enabled or disabled.
    constexpr std::uint16_t interestFlags(bool enabled) noexcept {
      return static_cast<std::uint16_t>(combineFlags(EV_ADD, enabled ? EV_ENABLE : EV_DISABLE));
    }

    constexpr EventKind eventKind(std::int16_t filter) noexcept {
      if (filter == EVFILT_SIGNAL) {
        return EventKind::signal;
      }

      return filter == EVFILT_WRITE ? EventKind::writable : EventKind::readable;
    }

    // kevent carries the caller's token in its pointer-sized udata.
    void* tokenData(std::uint64_t token) noexcept {
      return reinterpret_cast<void*>(token); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast,performance-no-int-to-ptr): kevent's udata is the only field that carries the token
    }

    std::uint64_t dataToken(const void* data) noexcept {
      return reinterpret_cast<std::uintptr_t>(data); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): kevent's udata is the only field that carries the token
    }

  }

  Kqueue::Kqueue()
      : queue_(::kqueue()) {
    if (!queue_) {
      throw SystemError{"create runtime event queue"};
    }

    setCloseOnExec(queue_.get());
  }

  template <Allocator Memory>
  Kqueue::Kqueue(Memory& /*memory*/)
      : Kqueue() {}

  void Kqueue::change(const struct kevent& event) {
    if (::kevent(queue_.get(), &event, 1, nullptr, 0, nullptr) != 0) {
      throw SystemError{"register runtime event"};
    }
  }

  void Kqueue::watch(int descriptor, std::uint64_t token) {
    readInterest(descriptor, token, true);
  }

  void Kqueue::readInterest(int descriptor, std::uint64_t token, bool enabled) {
    struct kevent event{};

    EV_SET(&event, static_cast<std::uintptr_t>(descriptor), EVFILT_READ, interestFlags(enabled), 0, 0, tokenData(token));
    change(event);
  }

  void Kqueue::writeInterest(int descriptor, std::uint64_t token, bool enabled) {
    struct kevent event{};

    EV_SET(&event, static_cast<std::uintptr_t>(descriptor), EVFILT_WRITE, interestFlags(enabled), 0, 0, tokenData(token));
    change(event);
  }

  void Kqueue::remove(int descriptor) noexcept {
    ds::Array<struct kevent, 2> events{};

    EV_SET(&events.atMut(0), static_cast<std::uintptr_t>(descriptor), EVFILT_READ, EV_DELETE, 0, 0, nullptr);
    EV_SET(&events.atMut(1), static_cast<std::uintptr_t>(descriptor), EVFILT_WRITE, EV_DELETE, 0, 0, nullptr);
    ::kevent(queue_.get(), events.data(), static_cast<int>(events.size()), nullptr, 0, nullptr);
  }

  void Kqueue::watchSignal(int signal_number) {
    struct kevent event{};

    EV_SET(&event, static_cast<std::uintptr_t>(signal_number), EVFILT_SIGNAL, interestFlags(true), 0, 0, nullptr);
    change(event);
    // Ignoring SIGCHLD discards the wait status; the event loop must reap it.
    static_cast<void>(::signal(signal_number, signal_number == SIGCHLD ? +[](int) {} : SIG_IGN));
  }

  tbc::val_a<std::span<const Event>> Kqueue::wait(std::chrono::nanoseconds timeout, tbc::val_a<std::span<Event>> events) {
    TELAR_ASSERT(events.size() >= event_capacity);
    timeout = std::max(timeout, std::chrono::nanoseconds::zero());
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(timeout);
    const timespec duration{.tv_sec = seconds.count(), .tv_nsec = (timeout - seconds).count()};
    const int count = ::kevent(queue_.get(), nullptr, 0, kernel_events_.dataMut(), static_cast<int>(kernel_events_.size()), &duration);

    if (count < 0) {
      if (sys::lastError() == EINTR) {
        return {};
      }

      throw SystemError{"wait for runtime event"};
    }

    const auto received = static_cast<std::size_t>(count);

    for (std::size_t index = 0; index < received; ++index) {
      const auto& source = kernel_events_[index];

      events[index] = Event{
          .kind = eventKind(source.filter),
          .descriptor = static_cast<int>(source.ident),
          .token = dataToken(source.udata),
          .closed = (source.flags & closed_flags) != 0,
      };
    }

    return std::span<const Event>{events}.first(received);
  }

  template Kqueue::Kqueue(SystemAllocator&);
  template Kqueue::Kqueue(Memory&);
  template Kqueue::Kqueue(ConcurrentMemory&);
  template Kqueue::Kqueue(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>&);

}
