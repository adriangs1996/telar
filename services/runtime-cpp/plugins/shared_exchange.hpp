#pragma once

#include "../exchange_capture/exchange.hpp"
#include "tap_budget.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
struct SharedExchange {
  explicit SharedExchange(TapBudget::Charge charge, std::uint64_t event_id, CapturedExchange<Memory> exchange) noexcept
      : charge(std::move(charge)), event_id(event_id), exchange(std::move(exchange)) {}

  static std::size_t capturedBytes(const CapturedExchange<Memory> &exchange) noexcept {
    return (exchange.request ? exchange.request->capturedBytes() : 0) + (exchange.response ? exchange.response->capturedBytes() : 0);
  }

  TapBudget::Charge charge;
  std::uint64_t event_id;
  CapturedExchange<Memory> exchange;
};

}
