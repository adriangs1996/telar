#pragma once

#include "../platform/completion_signal.hpp"
#include "../platform/local_listener.hpp"
#include "protocol.hpp"
#include <atomic>
#include <chrono>
#include <poll.h>
#include <thread>
#include <fcntl.h>

namespace telar::runtime::redirect {

struct PrivilegedPeer {
  static bool allows(uid_t uid) noexcept { return uid == 0; }
};

template <typename Sink, typename PeerPolicy = PrivilegedPeer>
class Ingress {
  struct Peer {
    FileDescriptor socket;
    Incoming incoming;
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    bool monitor = false;
  };

public:
  explicit Ingress(std::string_view path, Sink &sink) : listener_(path), sink_(sink), worker_([this] { run(); }) {}

  ~Ingress() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    worker_.join();
  }

  Ingress(const Ingress &) = delete;
  Ingress &operator=(const Ingress &) = delete;

  MonitorState status() const noexcept { return status_.load(std::memory_order_acquire); }
  void stop() noexcept {
    stop_requested_.store(true, std::memory_order_release);
    wake_.notify();
  }

private:
  void run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar redirect ingress: %s\n", error.what());
      }
    }
  }

  void step() {
    std::array<pollfd, maximum_peers + 2> descriptors{};
    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      descriptors[index + 2] = {.fd = peers_[index] ? peers_[index]->socket.get() : -1, .events = POLLIN, .revents = 0};
    }
    constexpr int poll_ms = 100;
    if (::poll(descriptors.data(), descriptors.size(), poll_ms) < 0 && errno != EINTR) {
      throw SystemError{"Poll redirected socket ingress"};
    }
    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }
    if (descriptors[1].revents & POLLIN) { wake_.drain(); }
    if (stop_requested_.exchange(false, std::memory_order_acq_rel)) {
      for (auto &peer : peers_) {
        if (peer && peer->monitor) {
          status_.store(MonitorState::stopping, std::memory_order_release);
          if (::send(peer->socket.get(), &stop_request, 1, 0) != 1) {
            status_.store(MonitorState::cleanup_required, std::memory_order_release);
            peer.reset();
          }
        }
      }
    }
    if (descriptors[0].revents & POLLIN) {
      accept();
    }
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto &peer = peers_[index];
      if (!peer) {
        continue;
      }
      const auto readiness = descriptors[index + 2].revents;
      bool close = readiness & (POLLERR | POLLNVAL);
      try {
        if (!peer->monitor && (readiness & (POLLIN | POLLHUP)) && peer->incoming.receive(peer->socket.get())) {
          if (peer->incoming.kind() == Kind::monitor) {
            peer->incoming.validateMonitor();
            if (std::ranges::any_of(peers_, [](const auto &candidate) { return candidate && candidate->monitor; })) {
              throw EncodingError{"A redirect helper already owns this endpoint"};
            }
            peer->monitor = true;
            status_.store(MonitorState::starting, std::memory_order_release);
            std::array<Byte, sizeof(std::uint32_t)> reply;
            plugins::FrameWriter writer{reply};
            writer.integer(static_cast<std::uint32_t>(::geteuid()));
            close = ::send(peer->socket.get(), reply.data(), reply.size(), 0) != static_cast<ssize_t>(reply.size());
          } else {
            auto connection = peer->incoming.take();
            connection.lifetime.reset(::fcntl(peer->socket.get(), F_DUPFD_CLOEXEC, 0));
            if (!connection.lifetime) {
              throw SystemError{"Keep redirected connection lifetime"};
            }
            const Byte admitted = sink_.adopt(std::move(connection)) ? 1 : 0;
            ::send(peer->socket.get(), &admitted, sizeof(admitted), 0);
            close = true;
          }
        } else if (peer->monitor && (readiness & (POLLIN | POLLHUP))) {
          close = advanceMonitor(*peer);
        }
      } catch (const std::exception &) {
        close = true;
      }
      if (close || (!peer->monitor && std::chrono::steady_clock::now() >= peer->deadline)) {
        if (peer->monitor) { status_.store(MonitorState::cleanup_required, std::memory_order_release); }
        peer.reset();
      }
    }
  }

  bool advanceMonitor(Peer &peer) {
    for (std::size_t count = 0; count < 3; ++count) {
      Byte update;
      const auto received = ::recv(peer.socket.get(), &update, 1, 0);
      if (received < 0 && socketWouldBlock(errno)) { return false; }
      if (received != 1) { return true; }
      if (update == static_cast<Byte>(MonitorUpdate::active) && (status() == MonitorState::starting || status() == MonitorState::stopping)) {
        if (status() == MonitorState::starting) { status_.store(MonitorState::active, std::memory_order_release); }
      } else if (update == static_cast<Byte>(MonitorUpdate::stopped)) {
        status_.store(MonitorState::idle, std::memory_order_release);
        peer.monitor = false;
        return true;
      } else { return true; }
    }
    return true;
  }

  void accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }
    uid_t uid;
    gid_t gid;
    if (::getpeereid(socket.get(), &uid, &gid) != 0 || !PeerPolicy::allows(uid)) {
      return;
    }
    for (auto &peer : peers_) {
      if (!peer) {
        peer.emplace();
        peer->socket = std::move(socket);
        return;
      }
    }
  }

  static constexpr std::size_t maximum_peers = 32;
  LocalListener listener_;
  Sink &sink_;
  CompletionSignal wake_;
  std::array<std::optional<Peer>, maximum_peers> peers_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> stop_requested_{false};
  std::atomic<MonitorState> status_{MonitorState::idle};
  std::thread worker_;
};

}
