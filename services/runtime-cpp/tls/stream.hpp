#pragma once

#include "session.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class TlsStream {
public:
  explicit TlsStream(TlsSession<Memory> &session, TlsSide side) noexcept : session_(session), side_(side) {}

  StreamResult read(std::span<std::uint8_t> destination) noexcept {
    return session_.read(side_, destination);
  }

  StreamResult peek(std::span<std::uint8_t> destination) noexcept {
    return session_.peek(side_, destination);
  }

  StreamView peekView(std::size_t maximum) noexcept {
    return session_.peekView(side_, maximum);
  }

  void consume(std::size_t count) noexcept {
    session_.consume(side_, count);
  }

  StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
    return session_.write(side_, bytes);
  }

  void halfClose() noexcept {
    session_.halfClose(side_);
  }

private:
  TlsSession<Memory> &session_;
  TlsSide side_;
};

template <ConcurrentAllocator Memory>
TlsStream(TlsSession<Memory> &session, TlsSide side) -> TlsStream<Memory>;

static_assert(ByteStream<TlsStream<SystemAllocator>>);
static_assert(PeekableByteStream<TlsStream<SystemAllocator>>);
static_assert(BufferedByteStream<TlsStream<SystemAllocator>>);

}
