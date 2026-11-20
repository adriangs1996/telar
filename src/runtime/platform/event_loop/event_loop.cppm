module;
#include "tbc/annotations.hpp"

export module telar.runtime.platform.event_loop;

import std;
#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
#endif
import telar.tbc;

import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.sys.process;
import telar.base.ds;

// Interface: platform/event_loop.cppm
export {
  namespace telar::runtime {

    enum class EventKind {
      readable,
      writable,
      signal,
    };

    struct Event {
      EventKind kind;
      int descriptor;
      std::uint64_t token;
      bool closed;
    };

#ifdef __APPLE__
    // Registering and removing descriptors invalidates nothing the queue hands out: events land in the
    // caller's buffer, so many objects may keep the queue.
    class TBC_SHARED Kqueue {
    public:
      Kqueue();

      template <Allocator Memory>
      explicit Kqueue(Memory&);

      void watch(int descriptor, std::uint64_t token);
      void readInterest(int descriptor, std::uint64_t token, bool enabled);
      void writeInterest(int descriptor, std::uint64_t token, bool enabled);
      void remove(int descriptor) noexcept;
      void watchSignal(int signal_number);

      static constexpr std::size_t event_capacity = 128;
      // Fills the caller's buffer, which holds event_capacity events, so registering descriptors while
      // the events are handled leaves them valid.
      tbc::val_a<std::span<const Event>> wait(std::chrono::nanoseconds timeout, tbc::val_a<std::span<Event>> events);

    private:
      void change(const struct kevent& event);

      FileDescriptor queue_;
      ds::Array<struct kevent, event_capacity> kernel_events_{};
    };

    extern template Kqueue::Kqueue(SystemAllocator&);
    extern template Kqueue::Kqueue(Memory&);
    extern template Kqueue::Kqueue(ConcurrentMemory&);
    extern template Kqueue::Kqueue(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>&);

#endif

    template <typename Poller>
    concept EventLoop = requires(Poller& poller, int descriptor, std::uint64_t token, std::chrono::nanoseconds timeout, std::span<Event> events) {
      { poller.watch(descriptor, token) } -> std::same_as<void>;
      { poller.readInterest(descriptor, token, true) } -> std::same_as<void>;
      { poller.writeInterest(descriptor, token, true) } -> std::same_as<void>;
      { poller.remove(descriptor) } noexcept -> std::same_as<void>;
      { Poller::event_capacity } -> std::convertible_to<std::size_t>;
      { poller.wait(timeout, events) } -> std::same_as<std::span<const Event>>;
    };

#ifdef __APPLE__
    template <Allocator Memory>
    using NativeEventLoop = Kqueue;

    static_assert(EventLoop<Kqueue>);
#endif

  }

#ifdef __linux__
  namespace telar::runtime {
    namespace linux_signals {

      struct Registration {
        std::atomic<int> destination{0};
        std::atomic<unsigned> writers{0};
        std::atomic<bool> pending{false};
      };

      static_assert(std::atomic<int>::is_always_lock_free && std::atomic<unsigned>::is_always_lock_free && std::atomic<bool>::is_always_lock_free);
      inline ds::Array<Registration, NSIG> registrations;

      void notify(int number) noexcept;

    }

    // Registering and removing descriptors invalidates nothing the queue hands out: events land in the
    // caller's buffer, so many objects may keep the queue.
    template <Allocator Memory>
    class TBC_SHARED Epoll {
      struct Interest {
        std::uint64_t token = 0;
        std::uint32_t mask = 0;
        std::uint32_t generation = 0;
        bool installed = false;
      };

    public:
      explicit Epoll(Memory& memory);

      ~Epoll();

      Epoll(const Epoll&) = delete;
      Epoll& operator=(const Epoll&) = delete;

      void watch(int descriptor, std::uint64_t token);

      void readInterest(int descriptor, std::uint64_t token, bool enabled);

      void writeInterest(int descriptor, std::uint64_t token, bool enabled);

      void remove(int descriptor) noexcept;

      void watchSignal(int number);

      static constexpr std::size_t event_capacity = 384;

      // Fills the caller's buffer, which holds event_capacity events, so registering descriptors while
      // the events are handled leaves them valid.
      tbc::val_a<std::span<const Event>> wait(std::chrono::nanoseconds timeout, tbc::val_a<std::span<Event>> events);

    private:
      void change(int descriptor, std::uint64_t token, std::uint32_t kind, bool enabled);

      static constexpr unsigned descriptor_bits = 32;
      static constexpr std::size_t batch_capacity = 128;
      static_assert(NSIG - 1 <= batch_capacity);
      FileDescriptor queue_;
      ds::Vec<Interest, Memory> interests_;
      FileDescriptor signal_reader_;
      FileDescriptor signal_writer_;
      ds::Array<struct sigaction, NSIG> previous_signals_{};
      ds::Array<bool, NSIG> signals_{};
      ds::Array<epoll_event, batch_capacity> kernel_events_{};
      static_assert(event_capacity == batch_capacity * 3);
    };

    extern template class Epoll<SystemAllocator>;
    extern template class Epoll<Memory>;
    extern template class Epoll<ConcurrentMemory>;
    extern template class Epoll<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

    static_assert(EventLoop<Epoll<SystemAllocator>>);

  }

  namespace telar::runtime {
    template <Allocator Memory>
    using NativeEventLoop = Epoll<Memory>;
  }
#endif
}
