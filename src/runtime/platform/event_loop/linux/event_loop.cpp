module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.platform.event_loop;

import telar.sys.posix;
import telar.sys.process;
import telar.sys.linux_api;
import telar.platform.error;
import telar.base.ds;

namespace telar::runtime {
  namespace linux_signals {

    void notify(int number) noexcept {
      const int saved_error = sys::lastError();
      auto& registration = registrations.atMut(number);
      registration.writers.fetch_add(1);
      const auto destination = registration.destination.load();
      if (destination > 0 && !registration.pending.exchange(true)) {
        const auto value = static_cast<unsigned char>(number);
        ssize_t count;
        do {
          count = ::write(destination - 1, &value, sizeof(value));
        } while (count < 0 && sys::lastError() == EINTR);
      }
      registration.writers.fetch_sub(1);
      sys::setLastError(saved_error);
    }

  }

  template <Allocator Memory>
  Epoll<Memory>::Epoll(Memory& memory)
      : queue_(::epoll_create1(EPOLL_CLOEXEC)),
        interests_(memory) {
    if (!queue_) {
      throw SystemError{"Create runtime event queue"};
    }
  }

  template <Allocator Memory>
  Epoll<Memory>::~Epoll() {
    for (int number = 1; number < NSIG; ++number) {
      if (signals_[number]) {
        auto& registration = linux_signals::registrations.atMut(number);
        registration.destination.store(0);
        ::sigaction(number, &previous_signals_[number], nullptr);
        while (registration.writers.load() != 0) {
          ::sched_yield();
        }
      }
    }
  }

  template <Allocator Memory>
  void Epoll<Memory>::watch(int descriptor, std::uint64_t token) {
    if (descriptor >= 0 && static_cast<std::size_t>(descriptor) < interests_.size()) {
      auto& interest = interests_.atMut(descriptor);
      interest.mask = 0;
      ++interest.generation;
    }
    readInterest(descriptor, token, true);
  }

  template <Allocator Memory>
  void Epoll<Memory>::readInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLIN, enabled);
  }

  template <Allocator Memory>
  void Epoll<Memory>::writeInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLOUT, enabled);
  }

  template <Allocator Memory>
  void Epoll<Memory>::remove(int descriptor) noexcept {
    if (descriptor < 0 || static_cast<std::size_t>(descriptor) >= interests_.size()) {
      return;
    }

    auto& interest = interests_.atMut(descriptor);
    ::epoll_ctl(queue_.get(), EPOLL_CTL_DEL, descriptor, nullptr);
    interest.installed = false;
    interest.mask = 0;
    ++interest.generation;
  }

  template <Allocator Memory>
  void Epoll<Memory>::watchSignal(int number) {
    if (number <= 0 || number >= NSIG || number == SIGKILL || number == SIGSTOP) {
      throw SystemError{"Invalid runtime signal", EINVAL};
    }
    if (signals_[number]) {
      return;
    }
    auto& registration = linux_signals::registrations.atMut(number);
    if (registration.destination.load() != 0) {
      throw SystemError{"Runtime signal already has an event queue", EBUSY};
    }

    if (!signal_reader_) {
      int descriptors[2];
      if (::pipe2(descriptors, O_CLOEXEC | O_NONBLOCK) != 0) {
        throw SystemError{"Create runtime signal pipe"};
      }
      signal_reader_.reset(descriptors[0]);
      signal_writer_.reset(descriptors[1]);
      watch(signal_reader_.get(), 0);
    }

    struct sigaction action{};
    sys::signalHandler(action) = &linux_signals::notify;
    action.sa_flags = SA_RESTART;
    ::sigemptyset(&action.sa_mask);
    int unclaimed = 0;
    if (!registration.destination.compare_exchange_strong(unclaimed, signal_writer_.get() + 1)) {
      throw SystemError{"Runtime signal already has an event queue", EBUSY};
    }
    registration.pending.store(false);
    if (::sigaction(number, &action, &previous_signals_.atMut(number)) != 0) {
      registration.destination.store(0);
      throw SystemError{"Register runtime signal"};
    }
    signals_.atMut(number) = true;
  }

  template <Allocator Memory>
  tbc::view<std::span<const Event>, tbc::lt::a> Epoll<Memory>::wait(std::chrono::nanoseconds timeout, tbc::view<std::span<Event>, tbc::lt::a> events) {
    TELAR_ASSERT(events.size() >= event_capacity);
    timeout = std::max(timeout, std::chrono::nanoseconds::zero());
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(timeout);
    const timespec duration{.tv_sec = seconds.count(), .tv_nsec = (timeout - seconds).count()};
    // glibc's epoll_pwait2 and musl, which declares none, both reach this kernel call; with no
    // mask, the kernel ignores the mask's size.
    const auto count = static_cast<int>(::syscall(SYS_epoll_pwait2, queue_.get(), kernel_events_.data(), kernel_events_.size(), &duration, nullptr, 0));
    if (count < 0) {
      if (sys::lastError() == EINTR) {
        return {};
      }
      throw SystemError{"Wait for runtime event"};
    }

    std::size_t produced = 0;
    for (int index = 0; index < count; ++index) {
      const auto& event = kernel_events_[index];
      const auto descriptor = static_cast<int>(static_cast<std::uint32_t>(event.data.u64));
      const auto& interest = interests_[descriptor];
      if (!interest.installed || event.data.u64 >> descriptor_bits != interest.generation) {
        continue;
      }
      if (signal_reader_ && descriptor == signal_reader_.get()) {
        ds::Array<unsigned char, batch_capacity> pending;
        const auto ignored = ::read(descriptor, pending.dataMut(), pending.size());
        (void)ignored;
        for (int number = 1; number < NSIG; ++number) {
          if (signals_[number] && linux_signals::registrations.atMut(number).pending.exchange(false)) {
            events[produced++] = {EventKind::signal, number, 0, false};
          }
        }
        continue;
      }

      const bool closed = (event.events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0;
      if ((interest.mask & EPOLLIN) && ((event.events & EPOLLIN) || closed)) {
        events[produced++] = {EventKind::readable, descriptor, interest.token, closed};
      }
      if ((interest.mask & EPOLLOUT) && ((event.events & EPOLLOUT) || closed)) {
        events[produced++] = {EventKind::writable, descriptor, interest.token, closed};
      }
    }

    return std::span<const Event>{events}.first(produced);
  }

  template <Allocator Memory>
  void Epoll<Memory>::change(int descriptor, std::uint64_t token, std::uint32_t kind, bool enabled) {
    if (descriptor < 0 || ::fcntl(descriptor, F_GETFD) < 0) {
      throw SystemError{"Invalid runtime event descriptor", EBADF};
    }
    if (static_cast<std::size_t>(descriptor) >= interests_.size()) {
      interests_.resize(static_cast<std::size_t>(descriptor) + 1);
    }

    auto& interest = interests_.atMut(descriptor);
    if (interest.token != token) {
      ++interest.generation;
    }
    const auto mask = enabled ? interest.mask | kind : interest.mask & ~kind;
    if (mask == 0) {
      remove(descriptor);
      interest.token = token;
      return;
    }

    epoll_event event{};
    event.events = mask | EPOLLRDHUP;
    event.data.u64 = (static_cast<std::uint64_t>(interest.generation) << descriptor_bits) | static_cast<std::uint32_t>(descriptor);
    auto operation = interest.installed ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
    if (::epoll_ctl(queue_.get(), operation, descriptor, &event) != 0) {
      if (operation != EPOLL_CTL_MOD || sys::lastError() != ENOENT || ::epoll_ctl(queue_.get(), EPOLL_CTL_ADD, descriptor, &event) != 0) {
        throw SystemError{"Register runtime event"};
      }
    }

    interest.token = token;
    interest.mask = mask;
    interest.installed = true;
  }

  template class Epoll<SystemAllocator>;
  template class Epoll<Memory>;
  template class Epoll<ConcurrentMemory>;
  template class Epoll<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
