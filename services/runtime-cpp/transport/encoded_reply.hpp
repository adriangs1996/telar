#pragma once

#include "../memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

template <Allocator Memory>
class EncodedReply {
public:
  explicit EncodedReply(Memory &memory)
      : bytes_(AllocatorRef<Byte, Memory>{memory}) {
    bytes_.reserve(failure_capacity);
  }

  template <typename Message>
  void send(const Message &message) {
    static_assert(MessageSchema<Message>::direction == Direction::server);
    const auto length = Codec::encodedSize(message);
    if (length > max_payload_size) {
      throw std::bad_alloc{};
    }

    bytes_.resize(length);
    Codec::encode(message, bytes_);
  }

  std::span<const Byte> payload() const noexcept {
    return bytes_;
  }

private:
  static constexpr std::size_t failure_capacity = 256;
  Vector<Byte, Memory> bytes_;
};

}
