#pragma once

#include "telar_platform/error.hpp"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <csignal>
#include <fcntl.h>
#include <sched.h>
#include <sys/epoll.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <unistd.h>

namespace telar::runtime {
namespace linux_signals {

struct Registration {
  std::atomic<int> destination{0};
  std::atomic<unsigned> writers{0};
  std::atomic<bool> pending{false};
};

static_assert(std::atomic<int>::is_always_lock_free && std::atomic<unsigned>::is_always_lock_free && std::atomic<bool>::is_always_lock_free);
inline std::array<Registration, NSIG> registrations;

inline void notify(int number) noexcept {
  const int saved_error = errno;
  auto &registration = registrations[number];
  registration.writers.fetch_add(1);
  const auto destination = registration.destination.load();
  if (destination > 0 && !registration.pending.exchange(true)) {
    const auto value = static_cast<unsigned char>(number);
    ssize_t count;
    do {
      count = ::write(destination - 1, &value, sizeof(value));
    } while (count < 0 && errno == EINTR);
  }
  registration.writers.fetch_sub(1);
  errno = saved_error;
}

}

template <Allocator Memory>
class Epoll {
  struct Interest {
    std::uint64_t token = 0;
    std::uint32_t mask = 0;
    std::uint32_t generation = 0;
    bool installed = false;
  };

public:
  explicit Epoll(Memory &memory) : queue_(::epoll_create1(EPOLL_CLOEXEC)), interests_(AllocatorRef<Interest, Memory>{memory}) {
    if (!queue_) {
      throw SystemError{"Create runtime event queue"};
    }
  }

  ~Epoll() {
    for (int number = 1; number < NSIG; ++number) {
      if (signals_[number]) {
        auto &registration = linux_signals::registrations[number];
        registration.destination.store(0);
        ::sigaction(number, &previous_signals_[number], nullptr);
        while (registration.writers.load() != 0) {
          ::sched_yield();
        }
      }
    }
  }

  Epoll(const Epoll &) = delete;
  Epoll &operator=(const Epoll &) = delete;

  void watch(int descriptor, std::uint64_t token) {
    if (descriptor >= 0 && static_cast<std::size_t>(descriptor) < interests_.size()) {
      auto &interest = interests_[descriptor];
      interest.mask = 0;
      ++interest.generation;
    }
    readInterest(descriptor, token, true);
  }

  void readInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLIN, enabled);
  }

  void writeInterest(int descriptor, std::uint64_t token, bool enabled) {
    change(descriptor, token, EPOLLOUT, enabled);
  }

  void remove(int descriptor) noexcept {
    if (descriptor < 0 || static_cast<std::size_t>(descriptor) >= interests_.size()) {
      return;
    }

    auto &interest = interests_[descriptor];
    ::epoll_ctl(queue_.get(), EPOLL_CTL_DEL, descriptor, nullptr);
    interest.installed = false;
    interest.mask = 0;
    ++interest.generation;
  }

  void watchSignal(int number) {
    if (number <= 0 || number >= NSIG || number == SIGKILL || number == SIGSTOP) {
      throw SystemError{"Invalid runtime signal", EINVAL};
    }
    if (signals_[number]) {
      return;
    }
    auto &registration = linux_signals::registrations[number];
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
    action.sa_handler = &linux_signals::notify;
    action.sa_flags = SA_RESTART;
    ::sigemptyset(&action.sa_mask);
    int unclaimed = 0;
    if (!registration.destination.compare_exchange_strong(unclaimed, signal_writer_.get() + 1)) {
      throw SystemError{"Runtime signal already has an event queue", EBUSY};
    }
    registration.pending.store(false);
    if (::sigaction(number, &action, &previous_signals_[number]) != 0) {
      registration.destination.store(0);
      throw SystemError{"Register runtime signal"};
    }
    signals_[number] = true;
  }

  std::span<const Event> wait(std::chrono::nanoseconds timeout) {
    timeout = std::max(timeout, std::chrono::nanoseconds::zero());
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(timeout);
    const timespec duration{.tv_sec = seconds.count(), .tv_nsec = (timeout - seconds).count()};
#if defined(__GLIBC__)
    const auto count = ::epoll_pwait2(queue_.get(), kernel_events_.data(), kernel_events_.size(), &duration, nullptr);
#else
    // musl declares no epoll_pwait2; the kernel call takes the mask's size.
    const auto count = static_cast<int>(::syscall(SYS_epoll_pwait2, queue_.get(), kernel_events_.data(), kernel_events_.size(), &duration, nullptr, 0));
#endif
    if (count < 0) {
      if (errno == EINTR) {
        return {};
      }
      throw SystemError{"Wait for runtime event"};
    }

    std::size_t produced = 0;
    for (int index = 0; index < count; ++index) {
      const auto &event = kernel_events_[index];
      const auto descriptor = static_cast<int>(static_cast<std::uint32_t>(event.data.u64));
      const auto &interest = interests_[descriptor];
      if (!interest.installed || event.data.u64 >> descriptor_bits != interest.generation) {
        continue;
      }
      if (signal_reader_ && descriptor == signal_reader_.get()) {
        std::array<unsigned char, batch_capacity> pending;
        const auto ignored = ::read(descriptor, pending.data(), pending.size());
        (void)ignored;
        for (int number = 1; number < NSIG; ++number) {
          if (signals_[number] && linux_signals::registrations[number].pending.exchange(false)) {
            events_[produced++] = {EventKind::signal, number, 0, false};
          }
        }
        continue;
      }

      const bool closed = (event.events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0;
      if ((interest.mask & EPOLLIN) && ((event.events & EPOLLIN) || closed)) {
        events_[produced++] = {EventKind::readable, descriptor, interest.token, closed};
      }
      if ((interest.mask & EPOLLOUT) && ((event.events & EPOLLOUT) || closed)) {
        events_[produced++] = {EventKind::writable, descriptor, interest.token, closed};
      }
    }

    return std::span<const Event>{events_}.first(produced);
  }

private:
  void change(int descriptor, std::uint64_t token, std::uint32_t kind, bool enabled) {
    if (descriptor < 0 || ::fcntl(descriptor, F_GETFD) < 0) {
      throw SystemError{"Invalid runtime event descriptor", EBADF};
    }
    if (static_cast<std::size_t>(descriptor) >= interests_.size()) {
      interests_.resize(static_cast<std::size_t>(descriptor) + 1);
    }

    auto &interest = interests_[descriptor];
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
      if (operation != EPOLL_CTL_MOD || errno != ENOENT || ::epoll_ctl(queue_.get(), EPOLL_CTL_ADD, descriptor, &event) != 0) {
        throw SystemError{"Register runtime event"};
      }
    }

    interest.token = token;
    interest.mask = mask;
    interest.installed = true;
  }

  static constexpr unsigned descriptor_bits = 32;
  static constexpr std::size_t batch_capacity = 128;
  static_assert(NSIG - 1 <= batch_capacity);
  FileDescriptor queue_;
  Vector<Interest, Memory> interests_;
  FileDescriptor signal_reader_;
  FileDescriptor signal_writer_;
  std::array<struct sigaction, NSIG> previous_signals_{};
  std::array<bool, NSIG> signals_{};
  std::array<epoll_event, batch_capacity> kernel_events_{};
  std::array<Event, batch_capacity * 3> events_{};
};

static_assert(EventLoop<Epoll<SystemAllocator>>);

}
