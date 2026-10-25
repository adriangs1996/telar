#pragma once

#include "../platform/byte_stream.hpp"
#include "socket.hpp"
#include <unistd.h>

namespace telar::runtime {

class SocketStream {
public:
  explicit SocketStream(int descriptor) noexcept : descriptor_(descriptor) {}

  StreamResult read(std::span<std::uint8_t> destination) noexcept {
    const auto received = ::read(descriptor_, destination.data(), destination.size());
    return result(received, StreamReadiness::readable);
  }

  StreamResult peek(std::span<std::uint8_t> destination) noexcept {
    return result(::recv(descriptor_, destination.data(), destination.size(), MSG_PEEK), StreamReadiness::readable);
  }

  StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
    const auto sent = ::write(descriptor_, bytes.data(), bytes.size());
    return result(sent, StreamReadiness::writable);
  }

  void halfClose() noexcept {
    ::shutdown(descriptor_, SHUT_WR);
  }

private:
  static StreamResult result(ssize_t count, StreamReadiness waiting) noexcept {
    if (count > 0) {
      return {StreamResult::State::data, static_cast<std::size_t>(count)};
    }
    if (count == 0) {
      return {StreamResult::State::ended};
    }
    return socketWouldBlock(errno) ? StreamResult{StreamResult::State::blocked, 0, waiting} : StreamResult{StreamResult::State::failed};
  }

  int descriptor_;
};

static_assert(ByteStream<SocketStream>);
static_assert(PeekableByteStream<SocketStream>);

}
