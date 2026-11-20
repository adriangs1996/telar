module;
#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

export module telar.runtime.runtime.tests.client_peer;

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;

import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.terminal.control;
import telar.testing;
import telar.runtime.model.client_layouts;
import telar.wire.vocabulary;
import telar.runtime.model.slot_store;
import telar.base.ds;

using telar::testing::check;

export {
  // Collects what a worker service completed, with `arguments` for its collect. A collect that finds
  // the worker still holding its lock leaves the completion descriptor up for another wake, which
  // the runtime's event loop gives it: the outcome is taken once the descriptor is down.
  template <typename Service, typename... Arguments>
  void collectCompleted(Service& service, Arguments&&... arguments) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};

    for (;;) {
      pollfd completion{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&completion, 1, 2000) == 1);
      service.collect(arguments...);
      completion.revents = 0;
      if (::poll(&completion, 1, 0) == 0) {
        return;
      }

      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }
  }

  class ClientPeer {
  public:
    explicit ClientPeer(telar::ConcurrentMemory& memory, telar::runtime::RuntimeModel& model, telar::runtime::ClientStore& clients, telar::runtime::ClientRole role)
        : memory_(memory),
          model_(model),
          clients_(clients),
          id_(clients.nextId()) {
      int sockets[2];

      check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
      peer_ = telar::runtime::FileDescriptor{sockets[1]};
      timeval timeout{.tv_sec = 2, .tv_usec = 0};

      check(::setsockopt(peer_.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
      telar::runtime::setNonblocking(sockets[0]);
      auto client = telar::ds::makeBox<telar::runtime::ClientSession>(memory, memory, id_, telar::runtime::FileDescriptor{sockets[0]});

      client.getMut().role = role;
      client.getMut().connection.flagsMut().negotiated = true;
      const auto handle = clients.insert(id_, std::move(client));

      clients.find(id_)->event_identity = handle;
    }

    telar::runtime::ClientSession& session() const {
      auto* client = clients_.find(id_);

      check(client != nullptr);
      return *client;
    }

    int descriptor() const noexcept {
      return peer_.get();
    }

    template <typename Message>
    Message receive() {
      return std::get<Message>(receiveAny<Message>());
    }

    template <typename... Messages>
    std::variant<Messages...> receiveAny() {
      session().connection.write(telar::runtime::ResponseProjection{memory_, model_});
      telar::ds::Array<telar::Byte, telar::frame_prefix_size> prefix;

      readExact(prefix.viewMut());
      std::span<const telar::Byte> encoded_length = prefix;
      const auto length = telar::u32::decode(encoded_length);

      check(length <= payload_.size());
      auto payload = payload_.viewMut().first(length);

      readExact(payload);
      telar::DecodeStorage storage{decode_.viewMut()};
      telar::ds::Option<std::variant<Messages...>> result;

      ([&] {
        if (payload.front() == static_cast<telar::Byte>(telar::MessageSchema<Messages>::tag)) {
          result.emplace(std::in_place_type<Messages>, telar::Codec::decode<Messages>(payload, storage));
        }
      }(),
          ...);

      check(result.hasValue());
      return std::move(result.getMut());
    }

  private:
    void readExact(std::span<telar::Byte> bytes) {
      while (!bytes.empty()) {
        session().connection.write(telar::runtime::ResponseProjection{memory_, model_});
        const auto count = ::read(peer_.get(), bytes.data(), bytes.size());
        if (count < 0 && errno == EINTR) {
          continue;
        }

        check(count > 0);
        bytes = bytes.subspan(static_cast<std::size_t>(count));
      }
    }

    telar::ConcurrentMemory& memory_;
    telar::runtime::RuntimeModel& model_;
    telar::runtime::ClientStore& clients_;
    std::uint64_t id_;
    telar::runtime::FileDescriptor peer_;
    telar::ds::Array<telar::Byte, 64 * 1024 + 1024> payload_;
    telar::ds::Array<telar::Byte, 128 * 1024> decode_;
  };
}
