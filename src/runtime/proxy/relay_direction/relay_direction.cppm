module;
#include "tbc/annotations.hpp"

export module telar.runtime.proxy.relay_direction;

import std;
import telar.sys.socket;
import telar.sys.posix;

import telar.platform.net;

import telar.runtime.platform.name_resolutions;
import telar.base.text;
import telar.platform.primitives;
import telar.base.ds;

// Interface: proxy/origin_connection.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's resolver.
    template <HostnameResolver Resolver>
    class TBC_GENERIC OriginConnection {
    public:
      enum class State {
        resolving,
        connecting,
        connected,
        failed,
        resolution_refused,
      };

      inline explicit OriginConnection(std::string_view hostname, std::uint16_t port) noexcept
          : port_(port) {
        if (!ProxyHostname::validTarget(hostname)) {
          state_ = State::failed;
          return;
        }

        ds::Array<char, ProxyHostname::maximum_bytes + 1> terminated{};

        std::copy(hostname.begin(), hostname.end(), terminated.dataMut());
        in_addr numeric{};
        if (::inet_pton(AF_INET, terminated.data(), &numeric) == 1) {
          resolved_.addresses.atMut(0) = NetworkAddress::ipv4(numeric);
          resolved_.summary = {.found = 1, .error = 0};
          attemptNext();
          return;
        }

        resolution_ = Resolutions::request(hostname);
        if (!resolution_) {
          state_ = State::resolution_refused;
        }
      }

      inline State advance(bool writable) noexcept {
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

      inline State state() const noexcept {
        return state_;
      }

      [[nodiscard]] inline int descriptor() const noexcept {
        return socket_.get();
      }

      [[nodiscard]] inline std::size_t attempt() const noexcept {
        return next_address_;
      }

      [[nodiscard]] inline bool truncated() const noexcept {
        return resolved_.summary.found > Resolutions::maximum_addresses;
      }

    private:
      using Resolutions = NameResolutions<Resolver>;

      inline void attemptNext() noexcept {
        socket_.reset();
        const auto count = std::min(resolved_.summary.found, Resolutions::maximum_addresses);

        while (next_address_ < count) {
          auto& address = resolved_.addresses.atMut(next_address_++);

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

          if (sys::lastError() == EINPROGRESS || sys::lastError() == EINTR) {
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
      ds::Option<typename Resolutions::Ticket> resolution_;
      Resolutions::Result resolved_{};
      std::size_t next_address_ = 0;
    };

  }
}

// Interface: proxy/relay_direction.cppm
export {
  namespace telar::runtime {

    // The relay's loop for every read, generic over the caller's streams and buffer size.
    template <std::size_t BufferCapacity = 16 * 1024>
    class TBC_GENERIC RelayDirection {
      static_assert(BufferCapacity != 0);

    public:
      enum class Observation {
        received,
        forwarded,
      };
      static constexpr std::size_t capacity = BufferCapacity;

      struct Progress {
        std::size_t read = 0;
        std::size_t written = 0;

        [[nodiscard]] inline bool active() const noexcept {
          return read != 0 || written != 0;
        }
      };

      template <ByteStream Source, ByteStream Destination>
      inline Progress advance(Source& source, Destination& destination) noexcept {
        return advance(source, destination, [](Observation, std::span<const std::uint8_t>) noexcept {});
      }

      template <ByteStream Source, ByteStream Destination, typename Observer>
        requires requires(Observer observe, Observation stage, std::span<const std::uint8_t> bytes) {
          { observe(stage, bytes) } noexcept -> std::same_as<void>;
        }
      inline Progress advance(Source& source, Destination& destination, Observer observe) noexcept {
        Progress progress;

        if (wantsRead()) {
          const auto received = source.read(bytes_.viewMut());
          if (received.state == StreamResult::State::data) {
            length_ = received.bytes;
            progress.read = length_;
            read_waiting_ = StreamReadiness::readable;
            observe(Observation::received, std::span{bytes_}.first(length_));
          } else if (received.state == StreamResult::State::blocked) {
            read_waiting_ = received.waiting;
          } else {
            ended_ = true;
          }
        }

        if (wantsWrite()) {
          const auto sent = destination.write(std::span{bytes_}.subspan(offset_, length_ - offset_));
          if (sent.state == StreamResult::State::data) {
            progress.written = sent.bytes;
            offset_ += progress.written;
            write_waiting_ = StreamReadiness::writable;
            if (offset_ == length_) {
              observe(Observation::forwarded, std::span{bytes_}.first(length_));
              offset_ = 0;
              length_ = 0;
            }
          } else if (sent.state == StreamResult::State::blocked) {
            write_waiting_ = sent.waiting;
          } else {
            ended_ = true;
            offset_ = 0;
            length_ = 0;
          }
        }

        if (finished() && !shutdown_) {
          destination.halfClose();
          shutdown_ = true;
        }

        return progress;
      }

      [[nodiscard]] inline bool wantsRead() const noexcept {
        return !ended_ && length_ == 0;
      }

      [[nodiscard]] inline bool wantsWrite() const noexcept {
        return length_ != 0;
      }

      [[nodiscard]] inline bool finished() const noexcept {
        return ended_ && length_ == 0;
      }

      [[nodiscard]] inline StreamReadiness sourceInterest() const noexcept {
        return wantsRead() ? read_waiting_ : StreamReadiness::none;
      }

      [[nodiscard]] inline StreamReadiness destinationInterest() const noexcept {
        return wantsWrite() ? write_waiting_ : StreamReadiness::none;
      }

    private:
      ds::Array<std::uint8_t, capacity> bytes_;
      std::size_t offset_ = 0;
      std::size_t length_ = 0;
      StreamReadiness read_waiting_ = StreamReadiness::readable;
      StreamReadiness write_waiting_ = StreamReadiness::writable;
      bool ended_ = false;
      bool shutdown_ = false;
    };

  }
}
