#pragma once

#include "control_protocol.hpp"
#include "control_access.hpp"
#include "../memory/drop_channel.hpp"
#include "../memory/sensitive_allocation.hpp"
#include "../platform/completion_signal.hpp"
#include "../platform/local_listener.hpp"
#include "../proxy/socket.hpp"
#include <atomic>
#include <chrono>
#include <poll.h>
#include <thread>
#include <cstdio>

namespace telar::runtime::traffic::control {

// Administration has its own worker; certificate-store operations never run on
// the packet, proxy, or terminal workers. Each authenticated connection issues
// one bounded request. Closing a client only cancels delivery of its reply.
template <ConcurrentAllocator Memory, typename Handler>
class Service : public PackagePort {
  using Clock = std::chrono::steady_clock;
  struct Peer {
    explicit Peer(Memory &memory, FileDescriptor channel)
        : socket(std::move(channel)), input(memory, Limits::request_bytes + Protocol::prefix_bytes), output(memory, Limits::reply_bytes + Protocol::prefix_bytes) {}
    FileDescriptor socket;
    SensitiveAllocation<Memory> input;
    SensitiveAllocation<Memory> output;
    Clock::time_point deadline = Clock::now() + std::chrono::seconds{5};
    std::size_t expected = Protocol::prefix_bytes;
    std::size_t received = 0;
    std::size_t reply_bytes = 0;
    std::size_t sent = 0;
    std::optional<plugins::ServiceSpec> package;
  };

  struct Attachment {
    FileDescriptor socket;
    plugins::ServiceSpec package;
  };

public:
  explicit Service(Memory &memory, std::string_view path, Handler &handler)
      : memory_(memory), listener_(path), handler_(handler), worker_([this] { run(); }) {}

  ~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    worker_.join();
  }

  Service(const Service &) = delete;
  Service &operator=(const Service &) = delete;

  FileDescriptor openPackage(const plugins::ServiceSpec &package) override {
    if (!package.traffic() || package.plugin_id == 0 || package.generation == 0) { throw SystemError{"Package control capability denied", EACCES}; }
    std::array<int, 2> descriptors;
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) != 0) { throw SystemError{"Create package control channel"}; }
    FileDescriptor native{descriptors[0]}, client{descriptors[1]};
    configureProxySocket(native.get());
    configureProxySocket(client.get());
    if (!attachments_.publish({std::move(native), package})) { throw SystemError{"Package control attachment queue is full", EBUSY}; }
    wake_.notify();
    return client;
  }

private:
  void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try { step(); }
      catch (const std::exception &error) { std::fprintf(stderr, "telar network control: %s\n", error.what()); }
    }
  }

  void step() {
    std::array<pollfd, Limits::peers + 2> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto &peer = peers_[index];
      descriptors[index + 2] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(peer && peer->reply_bytes ? POLLOUT : POLLIN)};
    }
    if (::poll(descriptors.data(), descriptors.size(), 100) < 0 && errno != EINTR) { throw SystemError{"Poll network control"}; }
    if (stopping_.load(std::memory_order_acquire)) { return; }
    handler_.tick();

    if (descriptors[1].revents & POLLIN) {
      wake_.drain();
      while (auto attachment = attachments_.tryReceive()) {
        for (auto &peer : peers_) {
          if (!peer) { peer.emplace(memory_, std::move(attachment->socket)); peer->package = std::move(attachment->package); break; }
        }
      }
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) { continue; }
      const auto readiness = descriptors[index + 2].revents;
      bool close = (readiness & (POLLERR | POLLNVAL)) || Clock::now() >= peer->deadline;
      try {
        if (!close && (readiness & (POLLIN | POLLOUT | POLLHUP))) { close = advance(*peer); }
      } catch (const std::exception &) { close = true; }
      if (close) { peer.reset(); }
    }
    if (descriptors[0].revents & POLLIN) {
      auto socket = listener_.accept();
      if (!socket) { return; }
      for (auto &peer : peers_) {
        if (!peer) { peer.emplace(memory_, std::move(socket)); break; }
      }
    }
  }

  bool advance(Peer &peer) {
    if (peer.reply_bytes != 0) {
      const auto count = ::send(peer.socket.get(), peer.output.bytes().data() + peer.sent, peer.reply_bytes - peer.sent, 0);
      if (count < 0 && socketWouldBlock(errno)) { return false; }
      if (count <= 0) { return true; }
      peer.sent += static_cast<std::size_t>(count);
      return peer.sent == peer.reply_bytes;
    }
    for (std::size_t round = 0; round < 2; ++round) {
      const auto count = ::recv(peer.socket.get(), peer.input.bytes().data() + peer.received, peer.expected - peer.received, 0);
      if (count < 0 && socketWouldBlock(errno)) { return false; }
      if (count <= 0) { return true; }
      peer.received += static_cast<std::size_t>(count);
      if (peer.received != peer.expected) { return false; }
      if (peer.expected == Protocol::prefix_bytes) {
        plugins::FrameReader reader{peer.input.bytes().first(Protocol::prefix_bytes)};
        const auto length = reader.integer<std::uint32_t>();
        if (length == 0 || length > Limits::request_bytes) { return true; }
        peer.expected += length;
        continue;
      }
      const auto request = Protocol::request(peer.input.bytes().subspan(Protocol::prefix_bytes, peer.expected - Protocol::prefix_bytes));
      const auto output = peer.output.bytes().subspan(Protocol::prefix_bytes);
      std::span<const Byte> reply;
      try { reply = handler_.handle(request, output, stopping_, peer.package ? &*peer.package : nullptr); }
      catch (const std::exception &error) {
        reply = Protocol::encode(output, Reply{.result = Result::failed, .message = std::string_view{error.what()}.substr(0, 1024)});
      }
      const auto prefix = Protocol::prefix(reply.size());
      std::ranges::copy(prefix, peer.output.bytes().begin());
      peer.reply_bytes = prefix.size() + reply.size();
      peer.deadline = Clock::now() + std::chrono::seconds{5};
      return false;
    }
    return false;
  }

  Memory &memory_;
  LocalListener listener_;
  Handler &handler_;
  CompletionSignal wake_;
  std::array<std::optional<Peer>, Limits::peers> peers_;
  std::atomic<bool> stopping_{false};
  DropChannel<Attachment, Limits::peers, ChannelPolicy::keep_oldest> attachments_;
  std::thread worker_;
};

}
