#pragma once

#include "../exchange_capture/types.hpp"
#include <optional>
#include <span>

namespace telar::runtime::plugins {

enum class ExchangeProtocol : std::uint8_t {
  http11,
  h2,
  upgraded
};

struct HalfView {
  std::span<const std::uint8_t> head{};
  std::span<const std::uint8_t> body{};
  std::string_view encoding{};
  bool decoded = false;
  bool body_truncated = false;
  std::uint16_t status_code = 0;
  CaptureOutcome outcome = CaptureOutcome::failed;
  std::int64_t finished_at_ms = 0;
  bool head_truncated = false;
};

struct ExchangeIdentity {
  std::uint64_t id = 0;
  std::uint64_t generation = 0;
};

struct ExchangeView {
  ExchangeIdentity identity;
  ExchangeProtocol protocol = ExchangeProtocol::http11;
  CaptureKey key;
  std::string_view host{};
  std::string_view method{};
  std::string_view target{};
  std::int64_t started_at_ms = 0;
  std::optional<HalfView> request;
  std::optional<HalfView> response;
};

}
