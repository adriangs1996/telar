#pragma once

#include "../platform/event_loop.hpp"
#include "../platform/event_token.hpp"
#include "../transport/client_handshake.hpp"
#include "limit_service.hpp"

namespace telar::runtime {

template <Allocator Memory, EventLoop Poller>
class ClientAdmission {
public:
  explicit ClientAdmission(RuntimeModel<Memory> &model, Poller &poller, LimitService<Memory> &limits)
      : model_(model),
        poller_(poller),
        limits_(limits) {}

  ~ClientAdmission() {
    clear();
  }

  void begin(FileDescriptor descriptor) {
    constexpr std::size_t maximum_clients = 32;
    std::size_t reserved = 0;
    for (const auto &pending : pending_) {
      reserved += pending && pending->reservesClient();
    }
    const auto requested = model_.clients.size() + reserved + 1;
    const bool refused = requested > maximum_clients;
    if (refused) {
      limits_.report({"clients.max_clients", "clients", maximum_clients, requested, {}});
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] || generations_[slot] >= maximum_event_identity / capacity - 1) {
        continue;
      }

      ++generations_[slot];
      pending_[slot].emplace(std::move(descriptor), refused);
      ++count_;
      try {
        poller_.watch(pending_[slot]->descriptor(), token(slot));
      } catch (...) {
        drop(slot);
        throw;
      }
      return;
    }
    limits_.report({"clients.max_pending_handshakes", "handshakes", capacity, {}, {}});
  }

  template <typename Admit>
  void event(const Event &event, const Admit &admit) {
    const auto slot = eventIdentity(event.token) % capacity;
    auto &pending = pending_[slot];
    if (!pending || event.token != token(slot) || event.descriptor != pending->descriptor()) {
      return;
    }

    try {
      if (event.kind == EventKind::readable) {
        pending->read();
      }
      pending->write();
      switch (pending->stage()) {
      case ClientHandshake::Stage::accepted: {
        poller_.remove(pending->descriptor());
        auto descriptor = pending->takeDescriptor();
        pending.reset();
        --count_;
        admit(std::move(descriptor));
        break;
      }
      case ClientHandshake::Stage::rejected:
        drop(slot);
        break;
      case ClientHandshake::Stage::reply:
        poller_.readInterest(pending->descriptor(), event.token, false);
        poller_.writeInterest(pending->descriptor(), event.token, true);
        break;
      case ClientHandshake::Stage::prefix:
      case ClientHandshake::Stage::hello:
        break;
      }
    } catch (const std::exception &) {
      if (pending) {
        drop(slot);
      }
    }
  }

  void expire(std::chrono::steady_clock::time_point now) noexcept {
    if (count_ == 0) {
      return;
    }

    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot] && pending_[slot]->expired(now)) {
        drop(slot);
      }
    }
  }

  void clear() noexcept {
    for (std::size_t slot = 0; slot < capacity; ++slot) {
      if (pending_[slot]) {
        drop(slot);
      }
    }
  }

private:
  std::uint64_t token(std::size_t slot) const noexcept {
    return eventToken(EventSource::handshake, generations_[slot] * capacity + slot);
  }

  void drop(std::size_t slot) noexcept {
    poller_.remove(pending_[slot]->descriptor());
    pending_[slot].reset();
    --count_;
  }

  static constexpr std::size_t capacity = 16;
  std::array<std::optional<ClientHandshake>, capacity> pending_;
  std::array<std::uint64_t, capacity> generations_{};
  std::size_t count_ = 0;
  RuntimeModel<Memory> &model_;
  Poller &poller_;
  LimitService<Memory> &limits_;
};

}
