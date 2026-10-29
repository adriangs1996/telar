#pragma once

#include <cstddef>

namespace telar::gui {

class ImageDrawBudget {
public:
  static constexpr std::size_t capacity = 2048;

  [[nodiscard]] bool take() noexcept {
    if (used_ == capacity) {
      return false;
    }

    ++used_;
    return true;
  }

  [[nodiscard]] std::size_t used() const noexcept {
    return used_;
  }

private:
  std::size_t used_ = 0;
};

}
