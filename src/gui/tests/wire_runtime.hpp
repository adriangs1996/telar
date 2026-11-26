#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QLocalSocket>
#include <QObject>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#pragma once

import telar.client;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::test {

  class WireRuntime {
  public:
    explicit WireRuntime(QLocalSocket& socket)
        : socket_(socket),
          stream_(adapter_) {
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

    WireRuntime(const WireRuntime&) = delete;
    WireRuntime& operator=(const WireRuntime&) = delete;
    WireRuntime(WireRuntime&&) = delete;
    WireRuntime& operator=(WireRuntime&&) = delete;

    template <typename Message>
    void send(const Message& message) {
      std::vector<Byte> bytes(Codec::encodedSize(message));

      write(Codec::encode(message, bytes));
    }

    [[nodiscard]] std::size_t count(ClientTag tag) const {
      return static_cast<std::size_t>(std::ranges::count_if(received_, [tag](const auto& bytes) {
        return bytes.front() == static_cast<Byte>(tag);
      }));
    }

    template <typename Message>
    [[nodiscard]] Message last() const {
      const auto found = std::find_if(received_.rbegin(), received_.rend(), [](const auto& bytes) {
        return bytes.front() == static_cast<Byte>(MessageSchema<Message>::tag);
      });

      DecodeStorage storage{decode_.viewMut()};

      return Codec::decode<Message>(*found, storage);
    }

  private:
    void write(std::span<const Byte> payload) {
      ds::Array<Byte, frame_prefix_size> prefix{};
      std::span<Byte> output{prefix.viewMut()};

      u32::encode(static_cast<std::uint32_t>(payload.size()), output);
      const auto prefix_text = textView(prefix);
      const auto payload_text = textView(payload);

      socket_.write(prefix_text.data(), static_cast<qint64>(prefix_text.size()));
      socket_.write(payload_text.data(), static_cast<qint64>(payload_text.size()));
    }

    QLocalSocket& socket_;
    SystemAllocator memory_;
    MemoryAdapter<SystemAllocator> adapter_{memory_};
    application::FrameStream<telar::ConcurrentMemory> stream_;
    std::vector<std::vector<Byte>> received_;
    static constexpr std::size_t decode_capacity = 4096;
    mutable ds::Array<Byte, decode_capacity> decode_{};
    bool greeted_ = false;
  };

}
