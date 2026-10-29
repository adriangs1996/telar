#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

struct ProgressSample {
  static constexpr Byte maximum_percent = 100;
  std::uint64_t pane_id = 0;
  std::uint64_t attachment = 0;
  PaneProgressState state = PaneProgressState::remove;
  std::optional<Byte> percent = std::nullopt;

  [[nodiscard]] float reported() const noexcept {
    return static_cast<float>(std::min(percent.value_or(0), maximum_percent)) / maximum_percent;
  }

  bool operator==(const ProgressSample &) const = default;
};

class ProgressMotion {
public:
  static constexpr std::uint64_t duration_ns = 240'000'000;

  [[nodiscard]] float sample(ProgressSample report, std::uint64_t now_ns) noexcept {
    if (report.state == PaneProgressState::remove) {
      *this = {};
      return 0;
    }

    if (report.pane_id != pane_id_ || report.attachment != attachment_) {
      *this = {};
      pane_id_ = report.pane_id;
      attachment_ = report.attachment;
    }

    const auto target = report.reported();
    if (report.state != PaneProgressState::set || !report.percent || !known_) {
      from_ = target;
      to_ = target;
      known_ = report.percent.has_value() && report.state != PaneProgressState::indeterminate;
      duration_ = 0;

      return target;
    }

    if (target != to_) {
      from_ = value(now_ns);
      to_ = target;
      started_ns_ = now_ns;
      duration_ = from_ == target ? 0 : duration_ns;
    }

    return value(now_ns);
  }

  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept {
    if (now_ns < started_ns_) {
      return started_ns_;
    }

    return now_ns - started_ns_ < duration_ ? std::optional{started_ns_ + std::min(std::numeric_limits<std::uint64_t>::max() - started_ns_, duration_)} : std::nullopt;
  }

private:
  [[nodiscard]] float value(std::uint64_t now_ns) const noexcept {
    float phase = 0;
    if (now_ns >= started_ns_) {
      if (duration_ == 0 || now_ns - started_ns_ >= duration_) {
        return to_;
      }

      phase = static_cast<float>(now_ns - started_ns_) / static_cast<float>(duration_);
    }

    const auto remaining = 1 - phase;
    const auto eased = 1 - (remaining * remaining * remaining);

    return std::clamp(from_ + ((to_ - from_) * eased), 0.0F, 1.0F);
  }

  std::uint64_t pane_id_ = 0;
  std::uint64_t attachment_ = 0;
  std::uint64_t started_ns_ = 0;
  std::uint64_t duration_ = 0;
  float from_ = 0;
  float to_ = 0;
  bool known_ = false;
};

}
