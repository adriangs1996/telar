#pragma once

#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/file_descriptor.hpp"
#include <chrono>

namespace telar::runtime {

class ClientHandshake {
public:
  enum class Stage {
    prefix,
    hello,
    reply,
    accepted,
    rejected
  };

  explicit ClientHandshake(FileDescriptor descriptor, bool capacity_refused)
      : descriptor_(std::move(descriptor)),
        capacity_refused_(capacity_refused) {}

  void read() {
    for (unsigned attempt = 0; attempt < 2 && (stage_ == Stage::prefix || stage_ == Stage::hello); ++attempt) {
      const auto remaining = expected_bytes_ - used_bytes_;
      const auto count = ::read(descriptor_.get(), bytes_.data() + used_bytes_, remaining);
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        return;
      }
      if (count <= 0) {
        throw SystemError{"read client handshake"};
      }

      used_bytes_ += static_cast<std::size_t>(count);
      if (used_bytes_ != expected_bytes_) {
        return;
      }
      if (stage_ == Stage::prefix) {
        std::span<const Byte> prefix{bytes_.data(), frame_prefix_size};
        if (u32::decode(prefix) != HandshakeSchema<ClientHello>::payload_size) {
          throw EncodingError{"Invalid client hello size"};
        }
        expected_bytes_ += HandshakeSchema<ClientHello>::payload_size;
        stage_ = Stage::hello;
      } else {
        negotiate();
      }
    }
  }

  void write() {
    if (stage_ != Stage::reply) {
      return;
    }

    const auto count = ::write(descriptor_.get(), bytes_.data() + used_bytes_, expected_bytes_ - used_bytes_);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      return;
    }
    if (count <= 0) {
      throw SystemError{"write client handshake"};
    }

    used_bytes_ += static_cast<std::size_t>(count);
    if (used_bytes_ == expected_bytes_) {
      stage_ = accepted_ ? Stage::accepted : Stage::rejected;
    }
  }

  int descriptor() const noexcept {
    return descriptor_.get();
  }

  FileDescriptor takeDescriptor() noexcept {
    return std::move(descriptor_);
  }

  Stage stage() const noexcept {
    return stage_;
  }

  bool reservesClient() const noexcept {
    return !capacity_refused_;
  }

  bool expired(std::chrono::steady_clock::time_point now) const noexcept {
    return now - started_at_ >= std::chrono::seconds{2};
  }

private:
  void negotiate() {
    const auto hello = HandshakeCodec::decode<ClientHello>(std::span<const Byte>{bytes_}.subspan(frame_prefix_size, HandshakeSchema<ClientHello>::payload_size));
    accepted_ = !capacity_refused_ && hello.schema == handshake::schema_id;
    if (accepted_) {
      reply(ServerAccept{.schema = handshake::schema_id});
    } else {
      reply(ServerReject{.reason = capacity_refused_ ? HandshakeRejectReason::client_limit_reached : HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});
    }
  }

  template <typename Message>
  void reply(const Message &message) {
    const auto payload = HandshakeCodec::encode(message);
    std::span<Byte> output = bytes_;
    u32::encode(payload.size(), output);
    std::copy(payload.begin(), payload.end(), output.begin());
    used_bytes_ = 0;
    expected_bytes_ = frame_prefix_size + payload.size();
    stage_ = Stage::reply;
  }

  FileDescriptor descriptor_;
  std::array<Byte, frame_prefix_size + HandshakeCodec::max_message_size> bytes_;
  std::size_t used_bytes_ = 0;
  std::size_t expected_bytes_ = frame_prefix_size;
  std::chrono::steady_clock::time_point started_at_ = std::chrono::steady_clock::now();
  Stage stage_ = Stage::prefix;
  bool capacity_refused_;
  bool accepted_ = false;
};

}
