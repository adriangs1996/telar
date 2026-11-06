#pragma once

#include "check.hpp"
#include "model/runtime_model.hpp"
#include "runtime/response_projection.hpp"
#include <sys/socket.h>
#include <optional>
#include <variant>

class ClientPeer {
public:
  explicit ClientPeer(telar::runtime::SystemAllocator &memory, telar::runtime::RuntimeModel<telar::runtime::SystemAllocator> &model, telar::runtime::ClientRole role)
      : memory_(memory),
        model_(model),
        id_(model.clients.nextId()) {
    int sockets[2];
    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    peer_ = telar::runtime::FileDescriptor{sockets[1]};
    timeval timeout{.tv_sec = 2,
                    .tv_usec = 0};
    check(::setsockopt(peer_.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    telar::runtime::setNonblocking(sockets[0]);
    auto client = telar::runtime::makeOwned<telar::runtime::ClientSession<telar::runtime::SystemAllocator>>(memory, memory, id_, telar::runtime::FileDescriptor{sockets[0]});
    client->role = role;
    client->connection.negotiated = true;
    model.clients.insert(id_, std::move(client));
  }

  telar::runtime::ClientSession<telar::runtime::SystemAllocator> &session() const {
    auto *client = model_.clients.find(id_);
    check(client != nullptr);
    return *client;
  }

  int descriptor() const noexcept { return peer_.get(); }

  template <typename Message>
  Message receive() {
    return std::get<Message>(receiveAny<Message>());
  }

  template <typename... Messages>
  std::variant<Messages...> receiveAny() {
    session().connection.write(telar::runtime::ResponseProjection{memory_, model_});
    std::array<telar::Byte, telar::frame_prefix_size> prefix;
    readExact(prefix);
    std::span<const telar::Byte> encoded_length = prefix;
    const auto length = telar::u32::decode(encoded_length);
    check(length <= payload_.size());
    auto payload = std::span{payload_}.first(length);
    readExact(payload);
    telar::DecodeStorage storage{decode_};
    std::optional<std::variant<Messages...>> result;
    ([&] {
      if (payload.front() == static_cast<telar::Byte>(telar::MessageSchema<Messages>::tag)) {
        result.emplace(std::in_place_type<Messages>, telar::Codec::decode<Messages>(payload, storage));
      }
    }(), ...);
    check(result.has_value());
    return std::move(*result);
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

  telar::runtime::SystemAllocator &memory_;
  telar::runtime::RuntimeModel<telar::runtime::SystemAllocator> &model_;
  std::uint64_t id_;
  telar::runtime::FileDescriptor peer_;
  std::array<telar::Byte, 64 * 1024 + 1024> payload_;
  std::array<telar::Byte, 128 * 1024> decode_;
};
