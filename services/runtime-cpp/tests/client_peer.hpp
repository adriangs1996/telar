#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "../diagnostics/line.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <array>
#include <span>
#include <sys/types.h>
#include "telar_base/memory/allocator.hpp"
#include <chrono>
#include <cstdint>
#include <bit>
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstring>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <algorithm>
#include <optional>
#include "../graphics/kitty_framing.hpp"
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "telar_config/graphics/limits.hpp"
#include "telar_platform/trace.hpp"
#include <limits>
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include <tuple>
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#include <sys/socket.h>

#pragma once



import telar.runtime.model.client_layouts;
import telar.runtime.runtime.delivery.client_delivery;

class ClientPeer {
public:
  explicit ClientPeer(telar::SystemAllocator &memory, telar::runtime::RuntimeModel<telar::SystemAllocator> &model, telar::runtime::ClientStore<telar::SystemAllocator> &clients, telar::runtime::ClientRole role)
      : memory_(memory),
        model_(model),
        clients_(clients),
        id_(clients.nextId()) {
    int sockets[2];
    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    peer_ = telar::runtime::FileDescriptor{sockets[1]};
    timeval timeout{.tv_sec = 2,
                    .tv_usec = 0};
    check(::setsockopt(peer_.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    telar::runtime::setNonblocking(sockets[0]);
    auto client = telar::makeOwned<telar::runtime::ClientSession<telar::SystemAllocator>>(memory, memory, id_, telar::runtime::FileDescriptor{sockets[0]});
    client->role = role;
    client->connection.negotiated = true;
    const auto handle = clients.insert(id_, std::move(client));
    clients.find(id_)->event_identity = handle;
  }

  telar::runtime::ClientSession<telar::SystemAllocator> &session() const {
    auto *client = clients_.find(id_);
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

  telar::SystemAllocator &memory_;
  telar::runtime::RuntimeModel<telar::SystemAllocator> &model_;
  telar::runtime::ClientStore<telar::SystemAllocator> &clients_;
  std::uint64_t id_;
  telar::runtime::FileDescriptor peer_;
  std::array<telar::Byte, 64 * 1024 + 1024> payload_;
  std::array<telar::Byte, 128 * 1024> decode_;
};
