module;

#include <concepts>
#include <cstdint>
#include <span>


#include <algorithm>
#include <cstring>
#include <string_view>


#include <optional>


#include <cstddef>
#include <array>
#include <cassert>

export module telar.runtime.platform.stream_read_buffer;

export import telar.runtime.metrics.host_sampler;


export import telar.base.memory;

// Interface: platform/byte_stream.cppm
export {
namespace telar::runtime {

enum class StreamReadiness {
  none,
  readable,
  writable,
  completion
};

struct StreamResult {
  enum class State {
    data,
    blocked,
    ended,
    failed
  };

  State state;
  std::size_t bytes = 0;
  StreamReadiness waiting = StreamReadiness::none;
};

struct StreamView {
  // The stream keeps these bytes stable until consume(), including write retries.
  StreamResult::State state;
  std::span<const std::uint8_t> bytes;
  StreamReadiness waiting = StreamReadiness::none;
};

template <typename Stream>
concept ByteStream = requires(Stream &stream, std::span<std::uint8_t> destination, std::span<const std::uint8_t> bytes) {
  { stream.read(destination) } noexcept -> std::same_as<StreamResult>;
  { stream.write(bytes) } noexcept -> std::same_as<StreamResult>;
  { stream.halfClose() } noexcept -> std::same_as<void>;
};

template <typename Stream>
concept PeekableByteStream = ByteStream<Stream> && requires(Stream &stream, std::span<std::uint8_t> destination) {
  { stream.peek(destination) } noexcept -> std::same_as<StreamResult>;
};

template <typename Stream>
concept BufferedByteStream = ByteStream<Stream> && requires(Stream &stream, std::size_t bytes) {
  { stream.peekView(bytes) } noexcept -> std::same_as<StreamView>;
  { stream.consume(bytes) } noexcept -> std::same_as<void>;
};

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
    too_large
  };

  template <PeekableByteStream Stream>
  inline Result receive(Stream &source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
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
    const auto bytes = std::string_view{reinterpret_cast<const char *>(storage.data()), available};
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

  inline std::size_t length() const noexcept {
    return length_;
  }

  inline StreamReadiness waiting() const noexcept {
    return waiting_;
  }

  inline void reset() noexcept {
    length_ = 0;
    complete_ = false;
    waiting_ = StreamReadiness::readable;
  }

private:
  template <BufferedByteStream Stream>
  inline Result receiveBuffered(Stream &source, std::span<std::uint8_t> storage, std::string_view delimiter) noexcept {
    const auto visible = source.peekView(storage.size() - length_);
    if (visible.state != StreamResult::State::data || visible.bytes.empty()) {
      return interrupted({visible.state, 0, visible.waiting});
    }

    const auto previous = std::string_view{reinterpret_cast<const char *>(storage.data()), length_};
    const auto incoming = std::string_view{reinterpret_cast<const char *>(visible.bytes.data()), visible.bytes.size()};
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

  inline static std::size_t delimiterEnd(std::string_view previous, std::string_view incoming, std::string_view delimiter) noexcept {
    const auto overlap = std::min(previous.size(), delimiter.size() - 1);
    for (std::size_t prefix = overlap; prefix != 0; --prefix) {
      const auto suffix = delimiter.size() - prefix;
      if (suffix <= incoming.size() && previous.ends_with(delimiter.substr(0, prefix)) && incoming.starts_with(delimiter.substr(prefix))) {
        return suffix;
      }
    }
    const auto position = incoming.find(delimiter);
    return position == std::string_view::npos ? position : position + delimiter.size();
  }

  inline Result interrupted(StreamResult result) noexcept {
    if (result.state == StreamResult::State::blocked) {
      waiting_ = result.waiting;
      return Result::pending;
    }
    return Result::ended;
  }

  std::size_t length_ = 0;
  bool complete_ = false;
  StreamReadiness waiting_ = StreamReadiness::readable;
};

}
}

// Interface: platform/event_token.cppm
export {
namespace telar::runtime {

inline constexpr std::uint64_t maximum_event_identity = UINT64_MAX >> 3;

enum class EventSource : std::uint64_t {
  listener = 0,
  client = 1,
  pane = 2,
  worker = 3,
  execution_output = 4,
  execution_error = 5,
  execution_input = 6,
  handshake = 7
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

// Interface: platform/host_metrics.cppm
export {
namespace telar::runtime {

class NativeHostMetrics {
public:
  std::optional<HostCounters> read() noexcept;
};

static_assert(HostMetricsProbe<NativeHostMetrics>);

}
}

// Interface: platform/stream_read_buffer.cppm
export {
namespace telar::runtime {

template <std::size_t Capacity>
class StreamReadBuffer {
public:
  template <typename Read>
    requires requires(Read read, std::span<std::uint8_t> destination) {
      { read(destination) } noexcept -> std::same_as<StreamResult>;
    }
  inline StreamView peek(Read read, std::size_t maximum) noexcept {
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

  inline std::size_t copyTo(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min(destination.size(), length_ - offset_);
    if (count != 0) {
      std::memcpy(destination.data(), storage_.bytes().data() + offset_, count);
      consume(count);
    }
    return count;
  }

  inline void consume(std::size_t count) noexcept {
    assert(count <= length_ - offset_);
    offset_ += count;
  }

  inline bool empty() const noexcept {
    return offset_ == length_;
  }

private:
  SensitiveBuffer<Capacity> storage_;
  std::size_t offset_ = 0;
  std::size_t length_ = 0;
};

}
}
