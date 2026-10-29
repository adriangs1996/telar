#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

class LoadingCue {
public:
  static constexpr std::uint64_t delay_ns = 150'000'000;

  [[nodiscard]] bool sample(bool waiting, std::optional<std::uint64_t> now_ns) noexcept {
    if (!waiting || !now_ns) {
      since_ns_.reset();

      return waiting;
    }

    const auto since = since_ns_.value_or(*now_ns);
    since_ns_ = since;

    return *now_ns >= visibleAt(since);
  }

  [[nodiscard]] std::optional<std::uint64_t> deadline() const noexcept {
    return since_ns_ ? std::optional{visibleAt(*since_ns_)} : std::nullopt;
  }

private:
  [[nodiscard]] static std::uint64_t visibleAt(std::uint64_t since_ns) noexcept {
    return since_ns + std::min(delay_ns, std::numeric_limits<std::uint64_t>::max() - since_ns);
  }

  std::optional<std::uint64_t> since_ns_;
};

}
