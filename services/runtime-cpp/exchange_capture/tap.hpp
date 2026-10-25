#pragma once

#include "exchange.hpp"

namespace telar::runtime {

template <typename Tap, typename Memory>
concept CaptureTap = Allocator<Memory> && requires(Tap &tap, CapturedExchange<Memory> &exchange) {
  { tap.listening() } noexcept -> std::same_as<bool>;
  { tap.submit(exchange) } noexcept -> std::same_as<void>;
};

struct IgnoreCaptureTap {
  bool listening() const noexcept { return false; }

  template <Allocator Memory>
  void submit(CapturedExchange<Memory> &) noexcept {}
};

}
