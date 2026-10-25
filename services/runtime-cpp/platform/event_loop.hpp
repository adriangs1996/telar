#pragma once

#include "file_descriptor.hpp"
#include <array>
#include <chrono>
#include <concepts>
#include <cstdint>
#include <span>
#include <sys/event.h>

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

class Kqueue {
public:
  Kqueue();
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

template <typename Poller>
concept EventLoop = requires(Poller &poller, int descriptor, std::uint64_t token, std::chrono::nanoseconds timeout) {
  { poller.watch(descriptor, token) } -> std::same_as<void>;
  { poller.readInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.writeInterest(descriptor, token, true) } -> std::same_as<void>;
  { poller.remove(descriptor) } noexcept -> std::same_as<void>;
  { poller.wait(timeout) } -> std::same_as<std::span<const Event>>;
};

static_assert(EventLoop<Kqueue>);

}
