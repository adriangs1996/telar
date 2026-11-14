module;
#include "tbc/annotations.hpp"
#include <cstddef>
#include <cstdint>
#include <cstring>

export module telar.runtime.platform.stream_read_buffer;

import std;
import telar.tbc;

export import telar.base.memory.sensitive;
export import telar.platform.net;

// Interface: platform/byte_stream.cppm
export {
  namespace telar::runtime {

    // A fixed message written to a peer as the peer accepts it.
    class StaticReply {
    public:
      constexpr StaticReply() noexcept = default;

      constexpr explicit StaticReply(tbc::view<std::string_view, tbc::lt::static_storage> text) noexcept
          : text_(text) {}

      // Whether there is no message to write at all.
      constexpr bool empty() const noexcept {
        return text_.empty();
      }

      constexpr bool sent() const noexcept {
        return offset_ == text_.size();
      }

      constexpr std::string_view remaining() const noexcept {
        return text_.substr(offset_);
      }

      // Writes what `stream` accepts now and returns the stream's result.
      // Generic over the caller's stream, so it stays a template here.
      template <ByteStream Stream>
      TBC_HOT_PATH inline StreamResult write(Stream& stream) noexcept {
        const auto rest = remaining();
        const auto result = stream.write({reinterpret_cast<const std::uint8_t*>(rest.data()), rest.size()});
        if (result.state == StreamResult::State::data) {
          offset_ += result.bytes;
        }

        return result;
      }

    private:
      tbc::view<std::string_view, tbc::lt::static_storage> text_;
      std::size_t offset_ = 0;
    };

    // Reads and discards what a refused peer still sends; true once its stream ended or failed.
    // Generic over the caller's stream, so it stays a template here.
    template <ByteStream Stream>
    TBC_HOT_PATH inline bool drainEnded(Stream& stream) noexcept {
      std::array<std::uint8_t, 4096> discarded;
      const auto read = stream.read(discarded);

      return read.state == StreamResult::State::ended || read.state == StreamResult::State::failed;
    }

  }
}

// Interface: platform/delimited_read.cppm
export {
  namespace telar::runtime {

    class DelimitedRead {
    public:
      enum class Result {
        pending,
        complete,
        ended,
        too_large,
      };

      // Generic over the caller's stream, so it stays a template here.
      template <PeekableByteStream Stream>
      TBC_HOT_PATH inline Result receive(Stream& source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
        if (complete_) {
          return Result::complete;
        }

        if (length_ == storage.size()) {
          return Result::too_large;
        }

        if constexpr (BufferedByteStream<Stream>) {
          return receiveBuffered(source, storage, delimiter);
        }

        const auto destination = storage.subspan(length_);
        const auto peeked = source.peek(destination);
        if (peeked.state != StreamResult::State::data || peeked.bytes == 0) {
          return interrupted(peeked);
        }

        const auto available = length_ + peeked.bytes;
        const auto bytes = std::string_view{reinterpret_cast<const char*>(storage.data()), available};
        const auto overlap = delimiter.size() - 1;
        const auto boundary = bytes.find(delimiter, length_ > overlap ? length_ - overlap : 0);
        const auto expected = boundary == std::string_view::npos ? available : boundary + delimiter.size();
        const auto consumed = source.read(destination.first(expected - length_));
        if (consumed.state != StreamResult::State::data || consumed.bytes == 0) {
          return interrupted(consumed);
        }

        length_ += consumed.bytes;
        waiting_ = StreamReadiness::readable;
        complete_ = boundary != std::string_view::npos && length_ == expected;
        return complete_ ? Result::complete : length_ == storage.size() ? Result::too_large
                                                                        : Result::pending;
      }

      std::size_t length() const noexcept;

      StreamReadiness waiting() const noexcept;

      void reset() noexcept;

    private:
      // Generic over the caller's stream, so it stays a template here.
      template <BufferedByteStream Stream>
      TBC_HOT_PATH inline Result receiveBuffered(Stream& source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
        const auto visible = source.peekView(storage.size() - length_);
        if (visible.state != StreamResult::State::data || visible.bytes.empty()) {
          return interrupted({visible.state, 0, visible.waiting});
        }

        const auto previous = std::string_view{reinterpret_cast<const char*>(storage.data()), length_};
        const auto incoming = std::string_view{reinterpret_cast<const char*>(visible.bytes.data()), visible.bytes.size()};
        const auto boundary = delimiterEnd(previous, incoming, delimiter);
        const auto consumed = boundary == std::string_view::npos ? visible.bytes.size() : boundary;

        std::memcpy(storage.data() + length_, visible.bytes.data(), consumed);
        source.consume(consumed);
        length_ += consumed;
        waiting_ = StreamReadiness::readable;
        complete_ = boundary != std::string_view::npos;
        return complete_ ? Result::complete : length_ == storage.size() ? Result::too_large
                                                                        : Result::pending;
      }

      static std::size_t delimiterEnd(std::string_view previous, std::string_view incoming, std::string_view delimiter) noexcept;

      Result interrupted(StreamResult result) noexcept;

      std::size_t length_ = 0;
      bool complete_ = false;
      StreamReadiness waiting_ = StreamReadiness::readable;
    };

  }
}

// Interface: platform/event_token.cppm
export {
  namespace telar::runtime {

    inline constexpr std::uint64_t maximum_event_identity = std::numeric_limits<std::uint64_t>::max() >> 3;

    enum class EventSource : std::uint64_t {
      listener = 0,
      client = 1,
      pane = 2,
      worker = 3,
      execution_output = 4,
      execution_error = 5,
      execution_input = 6,
      handshake = 7,
    };

    inline constexpr std::uint64_t eventToken(EventSource source, std::uint64_t identity) noexcept {
      constexpr unsigned source_bits = 3;

      return (identity << source_bits) | static_cast<std::uint64_t>(source);
    }

    inline constexpr std::uint64_t eventIdentity(std::uint64_t token) noexcept {
      constexpr unsigned source_bits = 3;

      return token >> source_bits;
    }

    inline constexpr EventSource eventSource(std::uint64_t token) noexcept {
      constexpr std::uint64_t source_mask = 7;

      return static_cast<EventSource>(token & source_mask);
    }

  }
}

// Interface: platform/stream_read_buffer.cppm
export {
  namespace telar::runtime {

    template <std::size_t Capacity>
    class StreamReadBuffer {
    public:
      // Generic over the caller's read, so it stays a template here.
      template <typename Read>
        requires requires(Read read, std::span<std::uint8_t> destination) {
          { read(destination) } noexcept -> std::same_as<StreamResult>;
        }
      TBC_HOT_PATH inline StreamView peek(Read read, std::size_t maximum) noexcept {
        if (empty()) {
          const auto received = read(storage_.bytes());
          if (received.state != StreamResult::State::data || received.bytes == 0) {
            return {received.state, {}, received.waiting};
          }

          offset_ = 0;
          length_ = received.bytes;
        }

        return {StreamResult::State::data, storage_.bytes().subspan(offset_, std::min(maximum, length_ - offset_))};
      }

      std::size_t copyTo(std::span<std::uint8_t> destination) noexcept;

      void consume(std::size_t count) noexcept;

      bool empty() const noexcept;

    private:
      SensitiveBuffer<Capacity> storage_;
      std::size_t offset_ = 0;
      std::size_t length_ = 0;
    };

    extern template class StreamReadBuffer<16 * 1024>;

  }
}
