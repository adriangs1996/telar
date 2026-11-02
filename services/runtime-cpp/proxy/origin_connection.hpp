#pragma once

#include "name_resolutions.hpp"
#include "socket.hpp"
#include <arpa/inet.h>

namespace telar::runtime {

template <HostnameResolver Resolver>
class OriginConnection {
public:
  enum class State {
    resolving,
    connecting,
    connected,
    failed,
    resolution_refused
  };

  explicit OriginConnection(std::string_view hostname, std::uint16_t port) noexcept
      : port_(port) {
    if (!ProxyHostname::validTarget(hostname)) {
      state_ = State::failed;
      return;
    }

    std::array<char, ProxyHostname::maximum_bytes + 1> terminated{};
    std::copy(hostname.begin(), hostname.end(), terminated.begin());
    sockaddr_in numeric{};
#if defined(__APPLE__)
    numeric.sin_len = sizeof(numeric);
#endif
    numeric.sin_family = AF_INET;
    if (::inet_pton(AF_INET, terminated.data(), &numeric.sin_addr) == 1) {
      resolved_.addresses.front() = *NetworkAddress::copy(reinterpret_cast<const sockaddr *>(&numeric), sizeof(numeric));
      resolved_.summary = {.found = 1, .error = 0};
      attemptNext();
      return;
    }

    resolution_ = Resolutions::request(hostname);
    if (!resolution_) {
      state_ = State::resolution_refused;
    }
  }

  State advance(bool writable) noexcept {
    if (state_ == State::resolving) {
      if (!resolution_->collect(resolved_)) {
        return state_;
      }
      resolution_.reset();
      if (resolved_.summary.error != 0) {
        state_ = State::failed;
      } else {
        attemptNext();
      }
    } else if (state_ == State::connecting && writable) {
      int failure = 0;
      socklen_t length = sizeof(failure);
      if (::getsockopt(socket_.get(), SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0) {
        state_ = State::connected;
      } else {
        attemptNext();
      }
    }
    return state_;
  }

  State state() const noexcept {
    return state_;
  }

  int descriptor() const noexcept {
    return socket_.get();
  }

  std::size_t attempt() const noexcept {
    return next_address_;
  }

  bool truncated() const noexcept {
    return resolved_.summary.found > Resolutions::maximum_addresses;
  }

private:
  using Resolutions = NameResolutions<Resolver>;

  void attemptNext() noexcept {
    socket_.reset();
    const auto count = std::min(resolved_.summary.found, Resolutions::maximum_addresses);
    while (next_address_ < count) {
      auto &address = resolved_.addresses[next_address_++];
      address.setPort(port_);
      try {
        socket_ = openOriginSocket(address.storage.ss_family);
      } catch (...) {
        continue;
      }

      if (::connect(socket_.get(), address.address(), address.length) == 0) {
        state_ = State::connected;
        return;
      }
      if (errno == EINPROGRESS || errno == EINTR) {
        state_ = State::connecting;
        return;
      }
      socket_.reset();
    }
    state_ = State::failed;
  }

  std::uint16_t port_;
  State state_ = State::resolving;
  FileDescriptor socket_;
  std::optional<typename Resolutions::Ticket> resolution_;
  typename Resolutions::Result resolved_{};
  std::size_t next_address_ = 0;
};

}
