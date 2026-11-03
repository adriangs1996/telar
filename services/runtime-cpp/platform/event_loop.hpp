#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <chrono>
#include <concepts>
#include <cstdint>
#include <span>
#if defined(__APPLE__)
#include <sys/event.h>
#endif

namespace telar::runtime {

enum class EventKind {
  readable,
  writable,
  signal
};

struct Event {
  EventKind kind;
  int descriptor;
  std::uint64_t token;
  bool closed;
};

#if defined(__APPLE__)
class Kqueue {
public:
  Kqueue();

  template <Allocator Memory>
  explicit Kqueue(Memory &) : Kqueue() {}
  void watch(int descriptor, std::uint64_t token);
  void readInterest(int descriptor, std::uint64_t token, bool enabled);
  void writeInterest(int descriptor, std::uint64_t token, bool enabled);
  void remove(int descriptor) noexcept;
  void watchSignal(int signal_number);
  std::span<const Event> wait(std::chrono::nanoseconds timeout);

private:
  void change(const struct kevent &event);

  FileDescriptor queue_;
  static constexpr std::size_t batch_capacity = 128;
  std::array<struct kevent, batch_capacity> kernel_events_{};
  std::array<Event, batch_capacity> events_{};
};

#endif

template <typename Poller>
concept EventLoop = requires(Poller &poller, int descriptor, std::uint64_t token, std::chrono::nanoseconds timeout) {
  { poller.watch(descriptor, token) } -> std::same_as<void>;
  { poller.readInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.writeInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.remove(descriptor) } noexcept -> std::same_as<void>;
  { poller.wait(timeout) } -> std::same_as<std::span<const Event>>;
};

#if defined(__APPLE__)
template <Allocator Memory>
using NativeEventLoop = Kqueue;

static_assert(EventLoop<Kqueue>);
#endif

}

#if defined(__linux__)
#include "linux/event_loop.hpp"
namespace telar::runtime {
template <Allocator Memory>
using NativeEventLoop = Epoll<Memory>;
}
#endif
