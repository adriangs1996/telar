#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include <array>
#include <cstddef>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <stdexcept>
#include <type_traits>
#include <QLocalSocket>
#include <QObject>
#include <algorithm>
#include <cstdint>
#include <vector>

#pragma once

#include "core/memory.hpp"


import telar.client;
import telar.gui.transport.runtime_link;

namespace telar::gui::test {

class WireRuntime {
public:
  explicit WireRuntime(QLocalSocket &socket)
      : socket_(socket),
        stream_(memory_) {
    QObject::connect(&socket_, &QLocalSocket::readyRead, &socket_, [this] {
      const auto bytes = socket_.readAll();
      const auto consume = [this](std::span<const Byte> payload) {
        if (!greeted_) {
          static_cast<void>(HandshakeCodec::decode<ClientHello>(payload));
          greeted_ = true;
        } else {
          received_.emplace_back(payload.begin(), payload.end());
        }
      };
      stream_.feed(byteView({bytes.constData(), static_cast<std::size_t>(bytes.size())}), consume);
    });
    write(HandshakeCodec::encode(ServerAccept{handshake::schema_id}));
  }

  ~WireRuntime() {
    QObject::disconnect(&socket_, nullptr, &socket_, nullptr);
  }

  WireRuntime(const WireRuntime &) = delete;
  WireRuntime &operator=(const WireRuntime &) = delete;
  WireRuntime(WireRuntime &&) = delete;
  WireRuntime &operator=(WireRuntime &&) = delete;

  template <typename Message>
  void send(const Message &message) {
    std::vector<Byte> bytes(Codec::encodedSize(message));
    write(Codec::encode(message, bytes));
  }

  [[nodiscard]] std::size_t count(ClientTag tag) const {
    return static_cast<std::size_t>(std::ranges::count_if(received_, [tag](const auto &bytes) {
      return bytes.front() == static_cast<Byte>(tag);
    }));
  }

  template <typename Message>
  [[nodiscard]] Message last() const {
    const auto found = std::find_if(received_.rbegin(), received_.rend(), [](const auto &bytes) {
      return bytes.front() == static_cast<Byte>(MessageSchema<Message>::tag);
    });

    DecodeStorage storage{decode_};

    return Codec::decode<Message>(*found, storage);
  }

private:
  void write(std::span<const Byte> payload) {
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(static_cast<std::uint32_t>(payload.size()), output);
    const auto prefix_text = textView(prefix);
    const auto payload_text = textView(payload);
    socket_.write(prefix_text.data(), static_cast<qint64>(prefix_text.size()));
    socket_.write(payload_text.data(), static_cast<qint64>(payload_text.size()));
  }

  QLocalSocket &socket_;
  SystemAllocator memory_;
  FrameStream<SystemAllocator> stream_;
  std::vector<std::vector<Byte>> received_;
  static constexpr std::size_t decode_capacity = 4096;
  mutable std::array<Byte, decode_capacity> decode_{};
  bool greeted_ = false;
};

}
