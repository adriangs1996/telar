#pragma once

#include "../platform/byte_stream.hpp"
#include "../platform/error.hpp"
#include <array>
#include <poll.h>
#include <sys/uio.h>
#include <unistd.h>
#include <utility>

namespace telar::runtime::plugins {

template <typename Wait>
concept PipeWait = requires(Wait &wait, int descriptor, short events) {
  { wait.active() } noexcept -> std::same_as<bool>;
  { wait.ready(descriptor, events) } noexcept -> std::same_as<bool>;
};

struct BlockingPipeWait {
  bool active() const noexcept { return true; }
  bool ready(int, short) const noexcept { return true; }
};

template <PipeWait Wait = BlockingPipeWait>
class PipeStream {
public:
  explicit PipeStream(int input, int output, Wait wait = {}) noexcept
      : input_(input), output_(output), wait_(std::move(wait)) {}

  Wait &wait() noexcept { return wait_; }
  const Wait &wait() const noexcept { return wait_; }

  StreamResult read(std::span<std::uint8_t> destination) noexcept {
    while (wait_.active()) {
      const auto count = ::read(input_, destination.data(), destination.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_.ready(input_, POLLIN)) {
        continue;
      }
      if (count < 0) {
        return {StreamResult::State::failed};
      }
      if (count == 0) {
        return {StreamResult::State::ended};
      }
      return {StreamResult::State::data, static_cast<std::size_t>(count)};
    }
    return {StreamResult::State::failed};
  }

  void write(std::span<const std::uint8_t> prefix, std::span<const std::uint8_t> payload) {
    std::array vectors{
        iovec{const_cast<std::uint8_t *>(prefix.data()), prefix.size()},
        iovec{const_cast<std::uint8_t *>(payload.data()), payload.size()},
    };
    std::size_t first = 0;
    while (first < vectors.size()) {
      if (!wait_.active()) {
        throw SystemError{"Wait for tap pipe"};
      }

      const auto count = ::writev(output_, vectors.data() + first, static_cast<int>(vectors.size() - first));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_.ready(output_, POLLOUT)) {
        continue;
      }
      if (count <= 0) {
        throw SystemError{"Write tap frame", count == 0 ? EPIPE : errno};
      }

      auto consumed = static_cast<std::size_t>(count);
      while (first < vectors.size() && consumed >= vectors[first].iov_len) {
        consumed -= vectors[first].iov_len;
        ++first;
      }
      if (first < vectors.size()) {
        vectors[first].iov_base = static_cast<std::uint8_t *>(vectors[first].iov_base) + consumed;
        vectors[first].iov_len -= consumed;
      }
    }
  }

private:
  int input_;
  int output_;
  Wait wait_;
};

template <PipeWait Wait = BlockingPipeWait>
PipeStream(int input, int output, Wait wait = {}) -> PipeStream<Wait>;

}
