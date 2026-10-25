#pragma once

#include "connection_policy.hpp"
#include "socket_interest.hpp"
#include "socket_stream.hpp"
#include <string_view>

namespace telar::runtime {

class ProxyRefusal {
public:
  explicit ProxyRefusal(FileDescriptor socket, ProxyConnectionPolicy::Time now) noexcept
      : socket_(std::move(socket)), deadline_(now + drain_duration) {}

  bool advance(ProxyConnectionPolicy::Time now) noexcept {
    if (now >= deadline_) {
      return true;
    }
    SocketStream stream{socket_.get()};
    if (offset_ < response.size()) {
      const auto sent = stream.write({reinterpret_cast<const std::uint8_t *>(response.data() + offset_), response.size() - offset_});
      if (sent.state != StreamResult::State::data) {
        return sent.state != StreamResult::State::blocked;
      }
      offset_ += sent.bytes;
      if (offset_ != response.size()) {
        return false;
      }
      stream.halfClose();
    }

    std::array<std::uint8_t, 4096> discarded;
    const auto read = stream.read(discarded);
    return read.state == StreamResult::State::ended || read.state == StreamResult::State::failed;
  }

  int descriptor() const noexcept {
    return socket_.get();
  }

  SocketInterest interest() const noexcept {
    return {.readable = offset_ == response.size(), .writable = offset_ != response.size()};
  }

  ProxyConnectionPolicy::Time deadline() const noexcept {
    return deadline_;
  }

private:
  static constexpr auto drain_duration = std::chrono::milliseconds{20};
  static constexpr std::string_view response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  FileDescriptor socket_;
  ProxyConnectionPolicy::Time deadline_;
  std::size_t offset_ = 0;
};

}
