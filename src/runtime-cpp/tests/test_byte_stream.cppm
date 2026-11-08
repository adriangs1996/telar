module;
#include <cstdint>
#include <cstring>

export module telar.runtime.tests.test_byte_stream;

import std;
export import telar.runtime.tests.check;
export import telar.runtime.platform.stream_read_buffer;

export {
class TestByteStream {
public:
  using Result = telar::runtime::StreamResult;
  using Readiness = telar::runtime::StreamReadiness;

  telar::runtime::StreamView peekView(std::size_t maximum) noexcept {
    const auto count = std::min({input.size() - offset, visible > offset ? visible - offset : 0, read_limit, maximum});
    if (count == 0) {
      return {ended ? Result::State::ended : Result::State::blocked, {}, Readiness::readable};
    }
    return {Result::State::data, {reinterpret_cast<const std::uint8_t *>(input.data() + offset), count}};
  }

  void consume(std::size_t count) noexcept {
    check(count <= input.size() - offset);
    offset += count;
  }

  Result peek(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min({input.size() - offset, visible > offset ? visible - offset : 0, read_limit, destination.size()});
    if (count == 0) {
      return ended ? Result{Result::State::ended} : Result{Result::State::blocked, 0, Readiness::readable};
    }
    std::memcpy(destination.data(), input.data() + offset, count);
    return {Result::State::data, count};
  }

  Result read(std::span<std::uint8_t> destination) noexcept {
    const auto result = peek(destination);
    offset += result.bytes;
    return result;
  }

  Result write(std::span<const std::uint8_t> bytes) noexcept {
    if (!pending.empty()) {
      check(pending.size() == bytes.size() && std::memcmp(pending.data(), bytes.data(), bytes.size()) == 0);
      pending.clear();
    }
    if (block_next_write) {
      pending.assign(reinterpret_cast<const char *>(bytes.data()), bytes.size());
      block_next_write = false;
      return {Result::State::blocked, 0, Readiness::writable};
    }
    const auto count = std::min(write_limit, bytes.size());
    output.append(reinterpret_cast<const char *>(bytes.data()), count);
    block_next_write = alternating_writes;
    return {Result::State::data, count};
  }

  void halfClose() noexcept {
    half_closed = true;
  }

  std::string input;
  std::string output;
  std::string pending;
  std::size_t offset = 0;
  std::size_t visible = std::numeric_limits<std::size_t>::max();
  std::size_t read_limit = std::numeric_limits<std::size_t>::max();
  std::size_t write_limit = std::numeric_limits<std::size_t>::max();
  bool ended = false;
  bool half_closed = false;
  bool alternating_writes = false;
  bool block_next_write = false;
};
}
