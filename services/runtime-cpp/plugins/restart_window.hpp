#pragma once

#include "limits.hpp"
#include <algorithm>
#include <array>

namespace telar::runtime::plugins {

class RestartWindow {
public:
  bool record(std::chrono::milliseconds now) noexcept {
    if (count_ < restarts_.size()) {
      restarts_[count_++] = now;
      return count_ == restarts_.size() && now - restarts_.front() <= Limits::restart_window;
    }
    if (now - restarts_.front() <= Limits::restart_window) {
      return true;
    }

    std::move(restarts_.begin() + 1, restarts_.end(), restarts_.begin());
    restarts_.back() = now;
    return false;
  }

private:
  std::array<std::chrono::milliseconds, Limits::restarts> restarts_;
  std::size_t count_ = 0;
};

}
