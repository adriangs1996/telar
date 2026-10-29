#pragma once

#include "core/cpu_history.hpp"
#include "telar_client/serializers/telar_messages.hpp"

namespace telar::gui {

class HostMetrics {
public:
  [[nodiscard]] bool update(const SystemMetrics &sample) {
    sample.validate();
    if (sample.revision <= sample_.revision) {
      return false;
    }

    sample_ = sample;
    history_.push(sample.cpu_percent);

    return true;
  }

  [[nodiscard]] const SystemMetrics &sample() const noexcept {
    return sample_;
  }

  [[nodiscard]] const CpuHistory &history() const noexcept {
    return history_;
  }

private:
  SystemMetrics sample_{};
  CpuHistory history_;
};

}
