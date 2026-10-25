#pragma once

#include <concepts>

namespace telar::runtime {

template <typename Source>
concept CaptureEventSource = requires(Source &source) {
  { source.descriptor() } noexcept -> std::same_as<int>;
  { source.collect() } noexcept -> std::same_as<bool>;
};

struct IgnoreCaptureEvents {
  int descriptor() const noexcept { return -1; }
  bool collect() noexcept { return false; }
};

}
