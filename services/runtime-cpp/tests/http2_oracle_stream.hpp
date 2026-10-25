#pragma once

#include "http2_oracle.hpp"
#include "platform/byte_stream.hpp"

class Http2OracleStream {
public:
  explicit Http2OracleStream(const Http2OracleInput &input, Http2OracleResult &result) noexcept : input_(input), result_(result) {}

  telar::runtime::StreamResult read(std::span<std::uint8_t> destination) noexcept {
    const auto count = std::min({destination.size(), input_.length - result_.consumed, input_.fragment});
    if (count == 0) {
      return {telar::runtime::StreamResult::State::ended};
    }
    std::memcpy(destination.data(), input_.bytes + result_.consumed, count);
    result_.consumed += count;
    return {telar::runtime::StreamResult::State::data, count};
  }

  telar::runtime::StreamResult write(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.size() > input_.fail_after - result_.forwarded) {
      return {telar::runtime::StreamResult::State::failed};
    }
    std::memcpy(input_.wire + result_.forwarded, bytes.data(), bytes.size());
    result_.forwarded += bytes.size();
    return {telar::runtime::StreamResult::State::data, bytes.size()};
  }

  void halfClose() noexcept {}

private:
  const Http2OracleInput &input_;
  Http2OracleResult &result_;
};
