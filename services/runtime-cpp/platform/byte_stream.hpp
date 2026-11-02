#pragma once

#include <concepts>
#include <cstdint>
#include <span>

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
