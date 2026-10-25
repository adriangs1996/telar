#pragma once

#include "../exchange_capture/types.hpp"
#include <concepts>
#include <span>

namespace telar::runtime {

template <typename Capture>
concept Http1CapturePolicy = requires(Capture &capture, CaptureSide side, std::string_view head, std::span<const std::uint8_t> body, std::uint16_t status) {
  { capture.begin() } noexcept -> std::same_as<void>;
  { capture.head(side, head) } noexcept -> std::same_as<void>;
  { capture.payload(side, body) } noexcept -> std::same_as<void>;
  { capture.finishRequest() } noexcept -> std::same_as<void>;
  { capture.finishResponse(status) } noexcept -> std::same_as<void>;
  { capture.discardInformational() } noexcept -> std::same_as<void>;
  { capture.fail() } noexcept -> std::same_as<void>;
};

struct IgnoreHttp1Capture {
  void begin() noexcept {}
  void head(CaptureSide, std::string_view) noexcept {}
  void payload(CaptureSide, std::span<const std::uint8_t>) noexcept {}
  void finishRequest() noexcept {}
  void finishResponse(std::uint16_t) noexcept {}
  void discardInformational() noexcept {}
  void fail() noexcept {}
};

static_assert(Http1CapturePolicy<IgnoreHttp1Capture>);

}
