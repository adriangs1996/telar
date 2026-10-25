#pragma once

#include "../memory/allocator.hpp"
#include "../memory/erasing_allocator.hpp"
#include "../memory/fixed_text.hpp"
#include "connection.hpp"
#include <chrono>
#include <csignal>
#include <optional>
#include <net/if.h>
#include <pcap/pcap.h>
#include <pthread.h>

namespace telar::runtime::traffic {

// This helper accepts no executable code, routing commands, CA keys or subscriber filters.
// Its only privileged operations are opening capture devices and reading their packets.
template <Allocator Memory>
class Capture {
  struct Device {
    explicit Device(pcap_t *value, std::string_view interface, std::uint32_t identity) : handle(value, &pcap_close), index(identity) {
      name.assign(interface);
    }

    std::unique_ptr<pcap_t, decltype(&pcap_close)> handle;
    FixedText<Limits::interface_bytes + 1> name;
    std::uint32_t index = 0;
    bool seen = false;
  };

public:
  explicit Capture(Memory &memory, FileDescriptor socket)
      : memory_(memory), socket_(std::move(socket)), output_(AllocatorRef<Byte, ErasingAllocator<Memory>>{memory_}) {
    output_.resize(Limits::frame_bytes + Protocol::prefix_bytes);
    ::arc4random_buf(&session_, sizeof(session_));
  }

  void live() {
    if (::geteuid() != 0) {
      throw std::invalid_argument{"Live interface capture requires the privileged capture helper"};
    }
    greet(Role::live_capture);
    Signals signals;
    auto discovery = std::chrono::steady_clock::time_point::min();
    while (!signals.stopped()) {
      const auto now = std::chrono::steady_clock::now();
      if (discovery == std::chrono::steady_clock::time_point::min() || now - discovery >= std::chrono::seconds{1}) {
        discover();
        statistics();
        discovery = now;
      }

      std::array<pollfd, Limits::interfaces + 1> descriptors{};
      descriptors[0] = {.fd = socket_.get(), .events = POLLIN, .revents = 0};
      for (std::size_t index = 0; index < devices_.size(); ++index) {
        descriptors[index + 1] = {.fd = devices_[index] ? pcap_get_selectable_fd(devices_[index]->handle.get()) : -1, .events = POLLIN, .revents = 0};
      }
      constexpr int poll_ms = 100;
      if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
        throw SystemError{"Poll packet capture"};
      }
      if (descriptors[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
        return;
      }
      drainControl();
      for (auto &device : devices_) {
        if (device) {
          drain(*device);
        }
      }
    }
  }

  void offline(const char *path) {
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> file{pcap_open_offline(path, error.data()), &pcap_close};
    if (!file) {
      throw std::runtime_error{error.data()};
    }
    greet(Role::offline_capture);
    offline_ = true;
    for (;;) {
      pcap_pkthdr *header;
      const u_char *bytes;
      const auto result = pcap_next_ex(file.get(), &header, &bytes);
      if (result == PCAP_ERROR_BREAK) {
        return;
      }
      if (result < 0) {
        throw std::runtime_error{pcap_geterr(file.get())};
      }
      if (result > 0) {
        packet(file.get(), *header, bytes, "offline", 0);
      }
      drainControl();
    }
  }

private:
  class Signals {
  public:
    Signals() {
      sigemptyset(&selected_);
      sigaddset(&selected_, SIGTERM);
      sigaddset(&selected_, SIGINT);
      const auto result = pthread_sigmask(SIG_BLOCK, &selected_, &previous_);
      if (result != 0) {
        throw SystemError{"Block capture shutdown signals", result};
      }
    }

    ~Signals() { pthread_sigmask(SIG_SETMASK, &previous_, nullptr); }

    bool stopped() const noexcept {
      sigset_t pending;
      return ::sigpending(&pending) == 0 && (sigismember(&pending, SIGTERM) || sigismember(&pending, SIGINT));
    }

  private:
    sigset_t selected_{};
    sigset_t previous_{};
  };

  void greet(Role role) {
    std::array<Byte, Protocol::greeting_bytes> output;
    sendAll(socket_.get(), Protocol::greeting(output, role));
    setNonblocking(socket_.get());
  }

  void drainControl() {
    std::array<Byte, Limits::metadata_bytes> bytes;
    const auto count = ::recv(socket_.get(), bytes.data(), bytes.size(), MSG_DONTWAIT);
    if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
      throw SystemError{"Traffic runtime disconnected", ECONNRESET};
    }
  }

  void emit(Event event) {
    event.session = session_;
    event.sequence = ++sequence_;
    event.offline = offline_;
    event.capture_drops = dropped_;
    const auto payload = Protocol::encode(std::span{output_}.subspan(Protocol::prefix_bytes), event);
    const auto prefix = Protocol::prefix(payload.size());
    std::ranges::copy(prefix, output_.begin());

    // Once any part of a frame is written it must finish, or close the channel.
    // Only a wholly unsent frame may be dropped under capture backpressure.
    const auto bytes = std::span<const Byte>{output_}.first(prefix.size() + payload.size());
    const auto count = ::send(socket_.get(), bytes.data(), bytes.size(), 0);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      ++dropped_;
      return;
    }
    if (count < 0 && errno == EINTR) {
      ++dropped_;
      return;
    }
    if (count <= 0) {
      throw SystemError{"Publish captured packet"};
    }
    auto remaining = bytes.subspan(static_cast<std::size_t>(count));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{1};
    while (!remaining.empty()) {
      pollfd descriptor{.fd = socket_.get(), .events = POLLOUT, .revents = 0};
      constexpr int write_poll_ms = 20;
      ::poll(&descriptor, 1, write_poll_ms);
      const auto written = ::send(socket_.get(), remaining.data(), remaining.size(), 0);
      if (written > 0) {
        remaining = remaining.subspan(static_cast<std::size_t>(written));
      } else if (written == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
        throw SystemError{"Publish partial capture frame"};
      }
      if (std::chrono::steady_clock::now() >= deadline) {
        throw SystemError{"Capture data channel stalled", ETIMEDOUT};
      }
    }
  }

  void notice(Kind kind, std::string_view interface, std::string_view message = {}) {
    emit(Event{.kind = kind, .interface = interface, .bytes = {reinterpret_cast<const Byte *>(message.data()), message.size()}});
  }

  void discover() {
    pcap_if_t *raw = nullptr;
    std::array<char, PCAP_ERRBUF_SIZE> error{};
    if (pcap_findalldevs(&raw, error.data()) < 0) {
      throw std::runtime_error{error.data()};
    }
    const std::unique_ptr<pcap_if_t, decltype(&pcap_freealldevs)> interfaces{raw, &pcap_freealldevs};
    for (auto &device : devices_) {
      if (device) {
        device->seen = false;
      }
    }

    for (auto *interface = raw; interface != nullptr; interface = interface->next) {
      const std::string_view name{interface->name};
      if ((interface->flags & PCAP_IF_UP) == 0 || name.size() > Limits::interface_bytes || ::if_nametoindex(interface->name) == 0) {
        continue;
      }
      auto existing = std::ranges::find_if(devices_, [&](auto &device) { return device && device->name.view() == name; });
      if (existing != devices_.end()) {
        (*existing)->seen = true;
        continue;
      }

      auto slot = std::ranges::find_if(devices_, [](auto &device) { return !device; });
      if (slot == devices_.end()) {
        notice(Kind::interface_error, name, "Capture interface limit reached");
        continue;
      }
      pcap_t *handle = pcap_create(interface->name, error.data());
      if (!handle) {
        notice(Kind::interface_error, name, error.data());
        continue;
      }
      slot->emplace(handle, name, ::if_nametoindex(interface->name));
      auto &capture = slot->value();
      constexpr int read_timeout_ms = 50;
      constexpr int kernel_buffer_bytes = 1024 * 1024;
      if (pcap_set_snaplen(handle, Limits::packet_bytes) != 0 || pcap_set_promisc(handle, 0) != 0 || pcap_set_timeout(handle, read_timeout_ms) != 0 || pcap_set_buffer_size(handle, kernel_buffer_bytes) != 0 || pcap_set_immediate_mode(handle, 1) != 0 || pcap_activate(handle) < 0 || pcap_setnonblock(handle, 1, error.data()) != 0) {
        notice(Kind::interface_error, name, pcap_geterr(handle));
        slot->reset();
        continue;
      }
      capture.seen = true;
      notice(Kind::interface_open, name);
    }

    for (auto &device : devices_) {
      if (device && !device->seen) {
        notice(Kind::interface_closed, device->name.view());
        device.reset();
      }
    }
  }

  void drain(Device &device) {
    constexpr std::size_t batch_packets = 64;
    for (std::size_t round = 0; round < batch_packets; ++round) {
      pcap_pkthdr *header;
      const u_char *bytes;
      const auto result = pcap_next_ex(device.handle.get(), &header, &bytes);
      if (result == 0) {
        return;
      }
      if (result < 0) {
        notice(Kind::interface_error, device.name.view(), pcap_geterr(device.handle.get()));
        return;
      }
      packet(device.handle.get(), *header, bytes, device.name.view(), device.index);
    }
  }

  void packet(pcap_t *handle, const pcap_pkthdr &header, const u_char *bytes, std::string_view interface, std::uint32_t index) {
    constexpr std::uint64_t micros_per_second = 1000000;
    const auto captured = std::min<std::size_t>(header.caplen, Limits::packet_bytes);
    emit(Event{
        .kind = Kind::packet,
        .timestamp_us = static_cast<std::uint64_t>(header.ts.tv_sec) * micros_per_second + static_cast<std::uint64_t>(header.ts.tv_usec),
        .interface_index = index,
        .link_type = static_cast<std::uint32_t>(pcap_datalink(handle)),
        .original_bytes = header.len,
        .interface = interface,
        .bytes = {bytes, captured},
    });
  }

  void statistics() {
    std::uint64_t drops = 0;
    for (const auto &device : devices_) {
      pcap_stat value{};
      if (device && pcap_stats(device->handle.get(), &value) == 0) {
        drops += value.ps_drop + static_cast<std::uint64_t>(value.ps_ifdrop);
      }
    }
    emit(Event{.kind = Kind::statistics, .kernel_drops = drops});
  }

  ErasingAllocator<Memory> memory_;
  FileDescriptor socket_;
  Vector<Byte, ErasingAllocator<Memory>> output_;
  std::array<std::optional<Device>, Limits::interfaces> devices_;
  std::uint64_t session_ = 0;
  std::uint64_t sequence_ = 0;
  std::uint64_t dropped_ = 0;
  bool offline_ = false;
};

template <Allocator Memory>
Capture(Memory &memory, FileDescriptor socket) -> Capture<Memory>;

}
