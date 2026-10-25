#pragma once

#include "http2/event.hpp"
#include <algorithm>
#include <cstring>

struct Http2OracleInput {
  const std::uint8_t *bytes;
  std::size_t length;
  std::uint8_t *wire;
  std::uint8_t *events;
  std::size_t event_capacity;
  std::size_t fragment;
  std::size_t fail_after;
  std::uint8_t response;
};

struct Http2OracleResult {
  std::size_t forwarded;
  std::size_t consumed;
  std::size_t events;
  std::uint32_t untracked;
  std::uint8_t failed;
  std::uint8_t block_limit;
  std::uint8_t overflow;
};

class Http2OracleEvents {
public:
  explicit Http2OracleEvents(const Http2OracleInput &input, Http2OracleResult &result) noexcept : input_(input), result_(result) {}

  void emit(const telar::runtime::Http2Event &event) noexcept {
    integer(static_cast<std::uint8_t>(event.kind), 1);
    integer(event.stream, 4);
    integer(event.status, 2);
    integer(event.event_stream, 1);
    text(event.name);
    text(event.value);
    integer(event.bytes.size(), 8);
    append(event.bytes);
  }

private:
  void integer(std::uint64_t value, std::size_t size) noexcept {
    std::uint8_t bytes[8];
    for (std::size_t index = 0; index < size; ++index) {
      bytes[index] = static_cast<std::uint8_t>(value >> (8 * index));
    }
    append({bytes, size});
  }

  void text(std::string_view value) noexcept {
    integer(value.size(), 8);
    append({reinterpret_cast<const std::uint8_t *>(value.data()), value.size()});
  }

  void append(std::span<const std::uint8_t> bytes) noexcept {
    if (bytes.size() > input_.event_capacity - result_.events) {
      result_.overflow = 1;
      return;
    }
    if (!bytes.empty()) {
      std::memcpy(input_.events + result_.events, bytes.data(), bytes.size());
      result_.events += bytes.size();
    }
  }

  const Http2OracleInput &input_;
  Http2OracleResult &result_;
};
