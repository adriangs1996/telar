#pragma once

#include "../platform/error.hpp"
#include "../platform/file_descriptor.hpp"
#include "port_range.hpp"
#include "socket.hpp"
#include <netinet/in.h>
#include <optional>
#include <poll.h>
#include <sys/socket.h>

namespace telar::runtime {

class ProxyListener {
public:
  static ProxyListener bind(std::optional<std::uint16_t> preferred, const ProxyPortRange::Set &reserved) {
    if (preferred) {
      if (auto listener = tryPort(*preferred, true)) {
        return std::move(*listener);
      }
    }

    for (const bool use_reserved : {false, true}) {
      for (std::uint16_t offset = 0; offset < ProxyPortRange::count; ++offset) {
        if (reserved.test(offset) != use_reserved) {
          continue;
        }
        if (auto listener = tryPort(ProxyPortRange::first + offset, false)) {
          return std::move(*listener);
        }
      }
    }
    throw SystemError{"No proxy port available", EADDRINUSE};
  }

  FileDescriptor accept() const {
    FileDescriptor child{::accept(socket_.get(), nullptr, nullptr)};
    if (!child) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return child;
      }
      throw SystemError{"Accept proxy connection"};
    }

    configureProxySocket(child.get());
    return child;
  }

  int descriptor() const noexcept {
    return socket_.get();
  }

  std::uint16_t port() const noexcept {
    return port_;
  }

  void close() noexcept {
    socket_.reset();
  }

private:
  explicit ProxyListener(FileDescriptor socket, std::uint16_t port) noexcept
      : socket_(std::move(socket)),
        port_(port) {}

  static FileDescriptor openSocket() {
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};
    if (!socket) {
      throw SystemError{"Create proxy socket"};
    }
    configureProxySocket(socket.get());
    return socket;
  }

  static sockaddr_in address(std::uint16_t port) noexcept {
    return {.sin_len = sizeof(sockaddr_in), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr = {htonl(INADDR_LOOPBACK)}, .sin_zero = {}};
  }

  static std::optional<ProxyListener> tryPort(std::uint16_t port, bool reclaim) {
    auto socket = listen(port, false);
    if (!socket && reclaim && !answers(port)) {
      // BSD reuse can shadow a wildcard listener; reclaim only a refused port.
      socket = listen(port, true);
    }
    if (!socket) {
      return std::nullopt;
    }
    return ProxyListener{std::move(socket), port};
  }

  static FileDescriptor listen(std::uint16_t port, bool reuse_closed) {
    auto socket = openSocket();
    if (reuse_closed) {
      const int enabled = 1;
      if (::setsockopt(socket.get(), SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0) {
        throw SystemError{"Reclaim proxy port"};
      }
    }

    const auto loopback = address(port);
    if (::bind(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) != 0 || ::listen(socket.get(), backlog) != 0) {
      if (errno == EADDRINUSE) {
        return FileDescriptor{};
      }
      throw SystemError{"Bind proxy listener"};
    }
    return socket;
  }

  static bool answers(std::uint16_t port) noexcept {
    try {
      auto socket = openSocket();
      const auto loopback = address(port);
      if (::connect(socket.get(), reinterpret_cast<const sockaddr *>(&loopback), sizeof(loopback)) == 0) {
        return true;
      }
      if (errno == ECONNREFUSED) {
        return false;
      }
      if (errno != EINPROGRESS) {
        return true;
      }

      pollfd pending{.fd = socket.get(), .events = POLLOUT, .revents = 0};
      if (::poll(&pending, 1, probe_timeout_ms) != 1) {
        return true;
      }
      int failure = 0;
      socklen_t length = sizeof(failure);
      return ::getsockopt(socket.get(), SOL_SOCKET, SO_ERROR, &failure, &length) != 0 || failure != ECONNREFUSED;
    } catch (...) {
      return true;
    }
  }

  static constexpr int backlog = 128;
  static constexpr int probe_timeout_ms = 50;
  FileDescriptor socket_;
  std::uint16_t port_;
};

}
